SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.bridge_attach_export (
  p_batch    uuid,
  p_file_ref text,
  p_held     jsonb,
  p_exported uuid[]
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  b finance.payout_batches;
  x record;
  po finance.payouts;
begin
  select * into b from finance.payout_batches pb where pb.id = p_batch for update;
  if not found then
    raise exception 'not_found:batch' using errcode = 'P0002';
  end if;
  if b.status = 'exported' and b.file_ref = p_file_ref then
    return;
  end if;
  if b.status <> 'approved' then
    raise exception 'invalid_state:%', b.status using errcode = 'P0001';
  end if;
  if p_file_ref is null or btrim(p_file_ref) = '' then
    raise exception 'invalid:file_ref' using errcode = 'P0001';
  end if;
  perform 1 from finance.payouts p where p.batch_id = b.id order by p.id for update;
  if exists (select 1 from unnest(coalesce(p_exported, '{}')) e(id)
              where not exists (select 1 from finance.payouts p where p.id = e.id and p.batch_id = b.id and p.status = 'requested'))
     or exists (select 1 from finance.payouts p where p.batch_id = b.id and p.status = 'requested'
                   and p.id <> all (coalesce(p_exported, '{}'))
                   and p.id not in (select h.payout_id from jsonb_to_recordset(coalesce(p_held, '[]')) h(payout_id uuid))) then
    raise exception 'export_stale' using errcode = 'P0001', detail = 'isi batch berubah sejak dibaca; ekspor ulang';
  end if;
  -- R21-1: sanksi (ban/suspend/flag) di antara get_batch dan sekarang → CSV basi ditolak; ekspor ulang menahan payout itu.
  -- Profil dikunci FOR SHARE supaya ban/suspend yang bersamaan menunggu sampai CSV ini diterima atau ditolak.
  perform 1 from market.profiles pr where pr.id in (select p.user_id from finance.payouts p where p.id = any (coalesce(p_exported, '{}')))
   order by pr.id for share;
  if exists (select 1 from finance.payouts p where p.id = any (coalesce(p_exported, '{}')) and finance.payout_block(p.user_id, p.id) is not null) then
    raise exception 'export_stale' using errcode = 'P0001', detail = 'clipper di CSV kena sanksi atau flag sejak dibaca; ekspor ulang';
  end if;
  for x in select * from jsonb_to_recordset(coalesce(p_held, '[]')) h(payout_id uuid, reason text) loop
    update finance.payouts set status = 'on_hold', hold_reason = coalesce(nullif(btrim(x.reason), ''), 'export_check_failed')
     where id = x.payout_id and batch_id = b.id and status = 'requested';
    if found then
      perform ops.raise_alert('payout.on_hold', 'warning', jsonb_build_object('payout_id', x.payout_id, 'batch_id', b.id,
                                                                                'reason', x.reason));
    end if;
  end loop;
  -- payout.processing per payout yang masuk CSV (eta = finance.payout_eta_batch_minutes); kirim ulang berkas sama = no-op di atas.
  for po in update finance.payouts set status = 'processing' where batch_id = b.id and status = 'requested' returning * loop
    perform finance.notify_payout_processing(po);
  end loop;
  update finance.payout_batches pb set status = 'exported', file_ref = p_file_ref,
         count = (select count(*) from finance.payouts p where p.batch_id = b.id and p.status = 'processing'),
         total = coalesce((select sum(p.amount - p.fee) from finance.payouts p where p.batch_id = b.id and p.status = 'processing'), 0)
   where pb.id = b.id;
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_mark_instant (
  p_payout       uuid,
  p_status       text,
  p_provider_ref text,
  p_error        text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  p finance.payouts;
begin
  if p_status is null or p_status not in ('processing', 'paid', 'failed') then
    raise exception 'invalid:status' using errcode = 'P0001';
  end if;
  select * into p from finance.payouts x where x.id = p_payout for update;
  if not found then
    raise exception 'not_found:payout' using errcode = 'P0002';
  end if;
  if p.channel <> 'instant' then
    raise exception 'invalid:channel' using errcode = 'P0001';
  end if;
  if p.status::text = p_status or (p_status = 'failed' and p.status = 'returned') or (p_status = 'processing' and p.status <> 'requested') then
    return;
  end if;
  begin
    if p.status = 'requested' then
      update finance.payouts set status = 'processing', provider_ref = coalesce(p_provider_ref, provider_ref) where id = p.id;
    elsif p_provider_ref is not null then
      update finance.payouts set provider_ref = p_provider_ref where id = p.id and provider_ref is null;
    end if;
  exception when unique_violation then
    raise exception 'duplicate_provider_ref' using errcode = '23505';
  end;
  if p_status = 'processing' then
    -- penyedia menerima transfer (eta = finance.payout_eta_instant_minutes); langsung paid/failed → hanya notifikasi akhirnya
    perform finance.notify_payout_processing(p);
  elsif p_status = 'paid' then
    update finance.payouts set status = 'paid', paid_at = now() where id = p.id;
    perform ops.enqueue_notification(p.user_id, 'payout.paid', finance.payout_notice(p, p.amount - p.fee)
                                     || jsonb_build_object('paid_at', now()));
  elsif p_status = 'failed' then
    perform finance.return_payout(p.id, p_error);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.cancel_payout (
  p_payout uuid,
  p_reason text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  po finance.payouts;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'invalid:reason' using errcode = 'P0001';
  end if;
  select * into po from finance.payouts p where p.id = p_payout for update;
  if not found then
    raise exception 'not_found:payout' using errcode = 'P0002';
  end if;
  if po.status = 'cancelled' then
    return;
  end if;
  if not (po.status = 'on_hold' or (po.status = 'requested' and po.channel = 'batch')) then
    raise exception 'invalid_state:%', po.status using errcode = 'P0001';
  end if;
  -- Batch approved = isi CSV transfer sedang/akan dibaca identity (get_batch → attach_export): payout requested di dalamnya
  -- tidak boleh dibatalkan, kalau tidak dananya kembali ke Tersedia sekaligus ikut ditransfer. FOR SHARE: serial dengan approve.
  if po.status = 'requested'
     and exists (select 1 from finance.payout_batches b where b.id = po.batch_id and b.status <> 'draft' for share) then
    raise exception 'batch_locked' using errcode = 'P0001',
      detail = 'batch sudah disetujui; tandai gagal setelah export bila perlu';
  end if;
  if po.status = 'requested' then
    update finance.payouts set status = 'on_hold', hold_reason = p_reason where id = po.id;
  end if;
  update finance.payouts set status = 'cancelled', hold_reason = p_reason where id = po.id;
  perform finance.unwind_payout_journal(po);
  perform ops.enqueue_notification(po.user_id, 'payout.cancelled', finance.payout_notice(po, po.amount)
                                   || jsonb_build_object('reason', p_reason));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout.cancel', 'payout:' || po.id, jsonb_build_object('status', po.status),
          jsonb_build_object('status', 'cancelled', 'reason', p_reason));
end $function$;

CREATE OR REPLACE FUNCTION api.invite_to_campaign (
  p_campaign  uuid,
  p_usernames text[]
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  pr record;
  n int := 0;
  k int;
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  if c.is_template or c.status in ('cancelled', 'rejected', 'settling', 'settled') then
    perform market.fail('invalid_state:' || c.status, 'campaign ini tidak bisa menerima undangan');
  end if;
  if coalesce(cardinality(p_usernames), 0) > 500 then
    perform market.fail('invalid:usernames', 'maks 500 username per panggilan');
  end if;
  for pr in select p.id from market.profiles p
             where p.status = 'active'
               and p.username in (select lower(btrim(ltrim(btrim(u), '@'))) from unnest(p_usernames) u) loop
    insert into market.campaign_invites (campaign_id, user_id, invited_by) values (c.id, pr.id, uid) on conflict do nothing;
    get diagnostics k = row_count;
    if k > 0 then
      n := n + 1;
      perform ops.enqueue_notification(pr.id, 'campaign.invited',
                                       jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'campaign_slug', c.slug,
                                                          'org_id', c.org_id,
                                                          'org_name', (select o.name from market.organizations o where o.id = c.org_id),
                                                          'rate_per_1k', market.rate_per_1k(c.id)));
    end if;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION api.mark_batch_paid (
  p_batch   uuid,
  p_results jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  b finance.payout_batches;
  x record;
  po finance.payouts;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into b from finance.payout_batches pb where pb.id = p_batch for update;
  if not found or b.status not in ('exported', 'paid', 'closed') then
    raise exception 'batch_not_exported' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_results) is distinct from 'array' then
    raise exception 'invalid:results' using errcode = 'P0001';
  end if;
  for x in select * from jsonb_to_recordset(p_results) r(payout_id uuid, status text, bank_ref text, reason text) loop
    select * into po from finance.payouts p where p.id = x.payout_id and p.batch_id = p_batch for update;
    if not found then
      raise exception 'payout_not_in_batch' using errcode = 'P0001';
    end if;
    continue when (po.status = 'paid' and x.status = 'paid') or (po.status = 'returned' and x.status = 'failed');
    if po.status <> 'processing' and not (po.status = 'paid' and x.status = 'failed') then  -- paid → failed = retur bank
      raise exception 'payout_not_in_export' using errcode = 'P0001';
    end if;
    if x.status = 'paid' then
      if coalesce(btrim(x.bank_ref), '') = '' then  -- referensi mutasi wajib: rekonsiliasi bank (A3.5) mencocokkan per referensi
        raise exception 'invalid:bank_ref' using errcode = 'P0001';
      end if;
      update finance.payouts set status = 'paid', paid_at = now(), bank_ref = btrim(x.bank_ref) where id = po.id;
      perform ops.enqueue_notification(po.user_id, 'payout.paid', finance.payout_notice(po, po.amount - po.fee)
                                       || jsonb_build_object('paid_at', now()));
    elsif x.status = 'failed' then
      update finance.payouts set bank_ref = x.bank_ref where id = po.id;
      perform finance.return_payout(po.id, coalesce(nullif(btrim(x.reason), ''), 'transfer gagal (batch)'));
    else
      raise exception 'invalid:result_status' using errcode = 'P0001';
    end if;
  end loop;
  if not exists (select 1 from finance.payouts p where p.batch_id = p_batch and p.status = 'processing') and b.status = 'exported' then
    update finance.payout_batches set status = 'paid', executed_at = now() where id = p_batch;
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout_batch.mark_paid', 'payout_batch:' || p_batch, jsonb_build_object('status', b.status),
          jsonb_build_object('results', p_results));
  perform finance.reconcile_bank();  -- kas sistem berubah (paid / retur bank) → status baris mutasi ikut diperbarui
end $function$;

CREATE OR REPLACE FUNCTION api.reset_social_account (
  p_account uuid,
  p_note    text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  a tracking.social_accounts;
begin
  if not ops.has_admin('admin_support', 'admin_moderator') then
    perform market.fail('auth:forbidden', 'butuh admin_support/admin_moderator aal2', '42501');
  end if;
  if nullif(btrim(coalesce(p_note, '')), '') is null then
    perform market.fail('invalid:reason', 'aksi admin atas user wajib alasan');
  end if;
  select * into a from tracking.social_accounts x where x.id = p_account for update;
  if not found then
    perform market.fail('not_found:social_account', null, 'P0002');
  end if;
  if a.status = 'disconnected' then
    perform market.fail('invalid_state:' || a.status);
  end if;
  delete from vault.secrets v where v.id = a.token_ref;
  update tracking.social_accounts set status = 'revoked', token_ref = null where id = a.id;
  update tracking.submissions set next_poll_at = null where social_account_id = a.id and status in ('tracking', 'flagged');
  perform ops.enqueue_notification(a.user_id, 'social.token_expired',
                                   jsonb_build_object('account_id', a.id, 'platform', a.platform, 'handle', a.handle,
                                                      'paused_count', tracking.paused_count(a.id)));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'social.reset', 'social_account:' || a.id, jsonb_build_object('status', a.status, 'user_id', a.user_id),
          jsonb_build_object('status', 'revoked', 'note', left(btrim(p_note), 500)));
end $function$;

CREATE OR REPLACE FUNCTION api.resolve_fraud_flag (
  p_flag   uuid,
  p_action text,
  p_note   text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  f trust.fraud_flags;
  target_user uuid;
  sub tracking.submissions;
  x record;
  score_delta smallint;
  notify boolean;
  amts jsonb;
begin
  if not ops.has_admin('admin_moderator') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('warn', 'hold', 'reverse', 'suspend', 'ban', 'dismiss') then
    raise exception 'invalid:action' using errcode = 'P0001';
  end if;
  select * into f from trust.fraud_flags ff where ff.id = p_flag for update;
  if not found then
    raise exception 'not_found:fraud_flag' using errcode = 'P0002';
  end if;
  if f.status not in ('open', 'held') then
    raise exception 'invalid_state:%', f.status using errcode = 'P0001';
  end if;
  target_user := case f.target_type
    when 'profile' then f.target_id
    when 'submission' then (select s.user_id from tracking.submissions s where s.id = f.target_id)
    when 'social_account' then (select a.user_id from tracking.social_accounts a where a.id = f.target_id)
    when 'payout' then (select p.user_id from finance.payouts p where p.id = f.target_id) end;
  if f.target_type = 'submission' then
    select * into sub from tracking.submissions s where s.id = f.target_id for update;
  end if;
  if p_action = 'reverse' and f.target_type not in ('submission', 'profile') then
    raise exception 'invalid:action_for_target' using errcode = 'P0001';
  end if;

  if p_action = 'hold' then
    update trust.fraud_flags set status = 'held' where id = f.id;
    if sub.status = 'tracking' then
      update tracking.submissions set status = 'flagged' where id = sub.id;
    end if;
    -- A4.2 "Clipper menerima notifikasi" untuk setiap tindakan, termasuk tahan.
    -- nominal yang ditahan: earning submisi belum rilis | payout | saldo Tersedia profil (DS: notif selalu ada angka)
    perform ops.enqueue_notification(target_user, 'earning.held',
                                     case when sub.id is null then '{}'::jsonb else market.campaign_ref(sub.campaign_id)
                                          || jsonb_build_object('submission_id', sub.id, 'platform', sub.platform,
                                                                'views', greatest(sub.counted_views, coalesce(sub.last_views, 0))) end
                                     || jsonb_build_object('target_type', f.target_type, 'signal', f.signal,
                                                           'amounts', case f.target_type
                                                             when 'submission' then finance.pending_amounts(sub.id)
                                                             when 'payout' then (select jsonb_build_array(finance.amount_ref(finance.idr(), p.amount))
                                                                                   from finance.payouts p where p.id = f.target_id)
                                                             when 'profile' then finance.wallet_amounts(target_user, 'available')
                                                             else '[]'::jsonb end)
                                     || case when f.target_type = 'payout' then jsonb_build_object('payout_id', f.target_id) else '{}' end);
    if f.target_type = 'payout' then
      -- Instant requested sudah diteruskan ke penyedia (alur 11); menahannya membuka refund saat transfer berjalan.
      update finance.payouts set status = 'on_hold', hold_reason = 'fraud:' || f.signal
       where id = f.target_id and status = 'requested' and channel = 'batch';
    end if;
  elsif p_action = 'dismiss' then
    update trust.fraud_flags set status = 'dismissed', resolved_by = uid, resolved_at = now() where id = f.id;
    if sub.status = 'flagged' and not exists (select 1 from trust.fraud_flags o where o.target_type = 'submission'
                                               and o.target_id = sub.id and o.status in ('open', 'held')) then
      update tracking.submissions set status = 'tracking', next_poll_at = coalesce(next_poll_at, now()) where id = sub.id;
    end if;
  else
    update trust.fraud_flags set status = 'actioned', resolved_by = uid, resolved_at = now() where id = f.id;
    if p_action = 'reverse' then
      for x in select s.id, s.status from tracking.submissions s
                where (f.target_type = 'submission' and s.id = f.target_id)
                   or (f.target_type = 'profile' and s.user_id = f.target_id and s.status in ('tracking', 'flagged', 'locked'))
                order by s.id loop
        -- submisi locked yang masih punya earning belum rilis juga kehilangan earning → clipper tetap dikabari
        notify := x.status <> 'locked' or exists (select 1 from finance.clip_earnings ce where ce.submission_id = x.id
                                                   and ce.released_at is null and ce.amount > 0);
        amts := finance.pending_amounts(x.id);  -- nominal hangus, dibaca sebelum reverse_earning
        perform finance.reverse_earning(x.id, 'fraud:' || f.signal);
        if x.status in ('tracking', 'flagged') then
          update tracking.submissions set status = 'forfeited', next_poll_at = null where id = x.id;
        end if;
        if notify then
          perform ops.enqueue_notification(target_user, 'submission.forfeited',
                                           (select market.campaign_ref(s.campaign_id)
                                                   || jsonb_build_object('platform', s.platform,
                                                                         'views', greatest(s.counted_views, coalesce(s.last_views, 0)))
                                              from tracking.submissions s where s.id = x.id)
                                           || jsonb_build_object('submission_id', x.id, 'reason', 'fraud:' || f.signal, 'amounts', amts));
        end if;
      end loop;
    elsif p_action = 'suspend' then
      update market.profiles set status = 'suspended', suspended_until = now() + interval '30 days'
       where id = target_user and status in ('active', 'suspended');
      perform finance.hold_payouts(target_user, null, 'profile_suspended');
      perform ops.enqueue_notification(target_user, 'account.suspended',
                                       jsonb_build_object('until', now() + interval '30 days', 'signal', f.signal));
    elsif p_action = 'ban' then
      update market.profiles set status = 'banned' where id = target_user and status <> 'closed';
      perform trust.apply_ban(target_user, f.signal, jsonb_build_object('signal', f.signal, 'flag_id', f.id));
      perform ops.invoke_function('bridge', jsonb_build_object('action', 'ban_user', 'user_id', target_user));
    elsif p_action = 'warn' then
      perform ops.enqueue_notification(target_user, 'account.warned', jsonb_build_object('signal', f.signal));
      -- peringatan = earning tetap jalan: submisi yang ditahan flag ini lanjut tracking bila tak ada flag lain (R30-5)
      if sub.status = 'flagged' and not exists (select 1 from trust.fraud_flags o where o.target_type = 'submission'
                                                 and o.target_id = sub.id and o.status in ('open', 'held')) then
        update tracking.submissions set status = 'tracking', next_poll_at = coalesce(next_poll_at, now()) where id = sub.id;
      end if;
    end if;
  end if;
  -- §12: setiap sanksi tercatat dan bisa dibanding sekali (trust.sanctions); ban fraud queue juga memblokir login identity
  if p_action <> 'dismiss' and target_user is not null then
    perform trust.record_sanction(target_user, p_action, f.id, p_note,
                                  case when p_action = 'suspend' then now() + interval '30 days' end, p_action = 'ban');
  end if;

  score_delta := case p_action when 'warn' then -5 when 'reverse' then -10 when 'suspend' then -20 when 'ban' then -50 end;
  if score_delta is not null and target_user is not null then
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by) values (target_user, score_delta, 'fraud_flag', f.id::text, uid);
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'fraud_flag.resolve', 'fraud_flag:' || f.id, jsonb_build_object('status', f.status),
          jsonb_build_object('action', p_action, 'note', p_note, 'target_user', target_user));
end $function$;

CREATE OR REPLACE FUNCTION api.worker_account_status (
  p_account uuid,
  p_status  text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  a tracking.social_accounts;
  new_status text := case p_status when 'expired' then 'token_expired' when 'revoked' then 'revoked' when 'verified' then 'verified' end;
begin
  if new_status is null then
    raise exception 'invalid:status' using errcode = 'P0001';
  end if;
  select * into a from tracking.social_accounts x where x.id = p_account for update;
  if not found then
    raise exception 'not_found:social_account' using errcode = 'P0002';
  end if;
  -- revoked lengket: hanya pulih lewat sambung ulang pemilik (worker_upsert_social_account), bukan hasil refresh/polling yang
  -- sedang jalan — termasuk 'expired' yang akan membuka jalan refresh menulis token lagi (R34-1, R35-1)
  if a.status in ('disconnected', 'revoked') then
    return;
  end if;
  if new_status = 'verified' then
    update tracking.social_accounts set status = 'verified', verified_at = now() where id = a.id;
    update tracking.submissions set next_poll_at = now()
     where social_account_id = a.id and status in ('tracking', 'flagged') and next_poll_at is null;
  else
    update tracking.social_accounts set status = new_status where id = a.id and status <> new_status;
    if a.status = 'verified' then
      perform ops.enqueue_notification(a.user_id, 'social.token_expired',
                                       jsonb_build_object('account_id', a.id, 'platform', a.platform, 'handle', a.handle,
                                                          'paused_count', tracking.paused_count(a.id)));
    end if;
    update tracking.submissions set next_poll_at = null where social_account_id = a.id and status in ('tracking', 'flagged');
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_post_gone (
  p_submission uuid,
  p_reason     text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  fid uuid;
  lost jsonb;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  if s.status not in ('tracking', 'flagged') then
    return;
  end if;
  lost := finance.pending_amounts(s.id);  -- nominal hangus untuk notifikasi, dibaca sebelum reverse_earning
  fid := trust.raise_flag('submission', s.id, 'FR-06', 100, jsonb_build_object('post_gone', true, 'reason', p_reason), 'actioned');
  -- §12 Trust Score turun dari fraud flag; FR-06 langsung ditindak tanpa antrean, jadi penaltinya di sini (setara reverse).
  insert into trust.score_events (user_id, delta, reason, ref_id)
  values (s.user_id, coalesce((ops.cfg('trust.score_deltas') ->> 'post_gone')::int, -10), 'fraud_flag', fid::text);
  update tracking.submissions set status = 'forfeited', next_poll_at = null where id = s.id;
  perform finance.reverse_earning(s.id, 'post_gone');
  perform ops.enqueue_notification(s.user_id, 'submission.forfeited', market.campaign_ref(s.campaign_id)
                                   || jsonb_build_object('submission_id', s.id, 'reason', coalesce(p_reason, 'post_gone'),
                                                         'platform', s.platform, 'views', greatest(s.counted_views, coalesce(s.last_views, 0)),
                                                         'amounts', lost));
end $function$;

CREATE OR REPLACE FUNCTION finance.clip_estimate (
  p_submission uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  c market.campaigns;
  cap numeric;
  hold int;
  v bigint;
begin
  select * into s from tracking.submissions t where t.id = p_submission;
  if not found then
    return '{}'::jsonb;
  end if;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  select ct.cap_pct, ct.hold_days into cap, hold
    from finance.clip_terms((select pr.trust_score from market.profiles pr where pr.id = s.user_id), s.platform::text) ct;
  v := greatest(s.counted_views, coalesce(s.last_views, 0));
  return jsonb_build_object(
    'platform', s.platform,
    'views', v,
    'rate_per_1k', market.rate_per_1k(c.id, s.platform::text),
    'est_amounts', coalesce((
      select jsonb_agg(finance.amount_ref(x.reward_type_id, x.amount) order by x.code)
        from (select rp.reward_type_id, rt.code, trunc(sum(e.amount), rt.decimals) as amount
                from finance.reward_pools rp
                join market.reward_types rt on rt.id = rp.reward_type_id
                cross join lateral (
                  select greatest(paid.amount, least(coalesce(sum(case
                           when r.kind = 'flat_per_post' then (r.params ->> 'amount')::numeric
                           when v < c.min_views then 0
                           when r.kind = 'milestone_bonus' then
                             case when v >= (r.params ->> 'threshold')::numeric then (r.params ->> 'amount')::numeric else 0 end
                           else finance.rule_amount(r.kind, r.params, 0, v) end), 0),
                         rp.max_per_clip * coalesce(cap, 100) / 100,
                         paid.amount + greatest(rp.total - rp.allocated, 0))) as amount
                    from (select coalesce(sum(ce.amount + ce.demand), 0) as amount from finance.clip_earnings ce
                           where ce.submission_id = s.id and ce.pool_id = rp.id) paid
                    left join market.rate_rules r on r.pool_id = rp.id
                          and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
                          and (r.platform is null or r.platform = s.platform)
                   group by paid.amount) e
               where rp.campaign_id = c.id
               group by rp.reward_type_id, rt.code, rt.decimals) x
       where x.amount > 0), '[]'),
    'release_at', coalesce(s.locked_at, s.posted_at + make_interval(days => coalesce(nullif(c.view_window_days, 0), 30)))
                  + make_interval(days => coalesce(hold, 7)));
end $function$;

CREATE OR REPLACE FUNCTION finance.notify_payout_processing (
  po finance.payouts
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  perform ops.enqueue_notification(po.user_id, 'payout.processing', finance.payout_notice(po, po.amount - po.fee)
                                   || jsonb_build_object('eta_at', finance.payout_eta(po.channel)));
end $function$;

CREATE OR REPLACE FUNCTION finance.payout_eta (
  p_channel text
)
  RETURNS timestamp WITH time zone
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return now() + (ops.cfg('finance.payout_eta_' || p_channel || '_minutes',
                          case p_channel when 'instant' then '2' else '30' end::jsonb))::numeric * interval '1 minute';
end $function$;

CREATE OR REPLACE FUNCTION finance.payout_notice (
  po       finance.payouts,
  p_amount numeric
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return finance.amount_ref(finance.idr(), p_amount)
         || jsonb_build_object('payout_id', po.id, 'payout_method_id', po.method_id, 'fee', trim_scale(po.fee),
                               'channel', po.channel);
end $function$;

CREATE OR REPLACE FUNCTION finance.pending_amounts (
  p_submission uuid
)
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select coalesce(jsonb_agg(finance.amount_ref(x.reward_type_id, x.amount) order by x.code), '[]')
    from (select rp.reward_type_id, rt.code, trunc(sum(ce.amount), rt.decimals) as amount
            from finance.clip_earnings ce join finance.reward_pools rp on rp.id = ce.pool_id
            join market.reward_types rt on rt.id = rp.reward_type_id
           where ce.submission_id = p_submission and ce.released_at is null
           group by rp.reward_type_id, rt.code, rt.decimals) x
   where x.amount > 0;
$function$;

CREATE OR REPLACE FUNCTION finance.release_earnings()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  hold int := (ops.cfg('public.finance.hold_days', '7'))::int;
  s record;
  g record;
  wallet uuid;
  avail numeric;
  entries jsonb;
  released jsonb;
  idr uuid := finance.idr();
  fee_pct numeric;
  fee numeric;
begin
  for s in select t.id, t.user_id, t.campaign_id, t.platform, t.counted_views from tracking.submissions t
            where t.status = 'locked'
              and t.locked_at <= now() - make_interval(days => coalesce(
                    (select ct.hold_days from finance.clip_terms((select pr.trust_score from market.profiles pr where pr.id = t.user_id),
                                                                 t.platform::text) ct), hold))
              and not exists (select 1 from trust.fraud_flags f where f.status in ('open', 'held')
                              and ((f.target_type = 'submission' and f.target_id = t.id)
                                or (f.target_type = 'profile' and f.target_id = t.user_id)
                                or (f.target_type = 'social_account' and f.target_id = t.social_account_id)))
              and not exists (select 1 from finance.clip_earnings ce where ce.submission_id = t.id and ce.demand > 0)
            order by t.locked_at limit 1000
            for update of t skip locked loop
    entries := '[]';
    released := '{}';
    -- Potongan earning clipper (E-21 clipper_fee_pct, default 0%): hanya Rupiah, dipotong saat Tertunda → Tersedia supaya
    -- reversal/koreksi (yang hanya menyentuh Tertunda) tidak perlu mengembalikan fee.
    fee_pct := coalesce((finance.effective_fee_rule((select c.org_id from market.campaigns c where c.id = s.campaign_id),
                                                    s.campaign_id)).clipper_fee_pct, 0);
    perform 1 from finance.reward_pools fp where fp.campaign_id = s.campaign_id order by fp.id for update;
    for g in select ce.pool_id, rp.reward_type_id, rt.code, rt.decimals, sum(ce.amount) as amount
               from finance.clip_earnings ce join finance.reward_pools rp on rp.id = ce.pool_id
               join market.reward_types rt on rt.id = rp.reward_type_id
              where ce.submission_id = s.id and ce.released_at is null
              group by ce.pool_id, rp.reward_type_id, rt.code, rt.decimals having sum(ce.amount) > 0
              order by ce.pool_id loop
      wallet := finance.account('user_wallet', s.user_id, g.reward_type_id);
      avail := trunc(g.amount, g.decimals);
      fee := case when g.reward_type_id = idr and fee_pct > 0 then trunc(avail * fee_pct / 100, g.decimals) else 0 end;
      entries := entries || jsonb_build_array(
        finance.e(wallet, -g.amount, 'release', s.id || ':' || g.pool_id, 'pending'),
        finance.e(wallet, avail - fee, 'release', s.id || ':' || g.pool_id, 'available'),
        finance.e(finance.account('campaign_pool', g.pool_id, g.reward_type_id), g.amount - avail, 'release', s.id || ':' || g.pool_id));
      if fee > 0 then
        entries := entries || jsonb_build_array(
          finance.e(finance.account('platform_revenue', null, idr), fee, 'fee', s.id || ':' || g.pool_id));
      end if;
      if g.amount > avail then
        update finance.reward_pools set allocated = allocated - (g.amount - avail) where id = g.pool_id;
      end if;
      avail := avail - fee;
      if avail > 0 then
        released := released || jsonb_build_object(g.reward_type_id::text,
                                                    coalesce((released ->> g.reward_type_id::text)::numeric, 0) + avail);
      end if;
    end loop;
    update finance.clip_earnings set released_at = now() where submission_id = s.id and released_at is null;
    update tracking.submissions set status = 'settled' where id = s.id;
    perform finance.post(gen_random_uuid(), entries);
    if released <> '{}' then
      perform ops.enqueue_notification(s.user_id, 'earning.available', market.campaign_ref(s.campaign_id) || jsonb_build_object(
        'submission_id', s.id, 'platform', s.platform, 'views', s.counted_views,
        'amounts', (select jsonb_agg(finance.amount_ref(x.key::uuid, x.value::numeric)) from jsonb_each_text(released) x)));
    end if;
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION finance.return_payout (
  p_payout uuid,
  p_error  text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  po finance.payouts;
begin
  select * into po from finance.payouts p where p.id = p_payout for update;
  if po.status = 'returned' then
    return;
  end if;
  if po.status in ('processing', 'paid') then
    update finance.payouts set status = 'failed', last_error = left(p_error, 500) where id = po.id;
  end if;
  update finance.payouts set status = 'returned' where id = po.id;  -- trigger S-05 menolak kalau bukan dari failed
  perform finance.unwind_payout_journal(po);
  perform ops.enqueue_notification(po.user_id, 'payout.failed', finance.payout_notice(po, po.amount)
                                   || jsonb_build_object('reason', left(p_error, 200)));
  perform ops.raise_alert('payout.failed', 'warning', jsonb_build_object('payout_id', po.id, 'channel', po.channel,
                                                                           'amount', po.amount, 'error', left(p_error, 500)));
end $function$;

CREATE OR REPLACE FUNCTION finance.wallet_amounts (
  p_user  uuid,
  p_state finance.earning_state
)
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select coalesce(jsonb_agg(finance.amount_ref(x.reward_type_id, x.amount) order by x.code), '[]')
    from (select a.reward_type_id, rt.code, trunc(sum(e.amount), rt.decimals) as amount
            from finance.ledger_accounts a join finance.ledger_entries e on e.account_id = a.id
            join market.reward_types rt on rt.id = a.reward_type_id
           where a.owner_type = 'user_wallet' and a.owner_id = p_user and e.state = p_state
           group by a.reward_type_id, rt.code, rt.decimals) x
   where x.amount > 0;
$function$;

CREATE OR REPLACE FUNCTION market.announce_campaign (
  p_campaign uuid
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  n int;
begin
  select count(ops.enqueue_notification(p.id, 'campaign.new', x.payload)) into n
    from market.campaigns c
    cross join lateral (select jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'campaign_slug', c.slug,
                                                  'org_name', (select o.name from market.organizations o where o.id = c.org_id),
                                                  'platforms', to_jsonb(c.platforms),
                                                  'rate_per_1k', market.rate_per_1k(c.id)) as payload) x
    join market.profiles p on p.status = 'active' and p.trust_score >= c.min_trust_score
   where c.id = p_campaign and not c.is_template
     and not exists (select 1 from market.org_members m where m.org_id = c.org_id and m.user_id = p.id)
     and (c.visibility <> 'invite' or exists (select 1 from market.campaign_invites i where i.campaign_id = c.id and i.user_id = p.id))
     -- Sekali per clipper per campaign: diumumkan ulang (F-B08) hanya menjangkau yang baru eligible.
     and not exists (select 1 from ops.notifications n where n.user_id = p.id and n.event = 'campaign.new'
                      and n.payload ->> 'campaign_id' = c.id::text)
     and exists (select 1 from tracking.social_accounts a
                 where a.user_id = p.id and a.status = 'verified' and a.platform = any (c.platforms)
                   and coalesce(a.followers, 0) >= c.min_followers
                   and (c.min_account_age_days = 0
                        or a.platform_created_at <= now() - make_interval(days => c.min_account_age_days)));
  return n;
end $function$;

CREATE OR REPLACE FUNCTION market.rate_per_1k (
  p_campaign uuid,
  p_platform text DEFAULT NULL::text
)
  RETURNS numeric
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  select trim_scale(max(x.rate)) from (
    select sum(market.rule_rate(r.kind, r.params)) as rate
      from unnest((select c.platforms from market.campaigns c where c.id = p_campaign)) pf(p)
      join market.rate_rules r on r.campaign_id = p_campaign and (r.platform is null or r.platform = pf.p)
      join market.reward_types rt on rt.id = r.reward_type_id and rt.code = 'IDR' and rt.owner_org_id is null
     where (p_platform is null or pf.p::text = p_platform)
       and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
     group by pf.p) x
   where x.rate > 0;
$function$;

CREATE OR REPLACE FUNCTION market.run_claim_expiry()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  c record;
begin
  for c in update market.claims set reminded_at = now()
            where status = 'open' and reminded_at is null and expires_at <= now() + interval '6 hours' and expires_at > now()
            returning id, user_id, campaign_id, expires_at loop
    perform ops.enqueue_notification(c.user_id, 'claim.expiring', market.campaign_ref(c.campaign_id)
                                     || jsonb_build_object('claim_id', c.id, 'expires_at', c.expires_at,
                                                           'hours_left', ceil(extract(epoch from c.expires_at - now()) / 3600)::int));
  end loop;
  update market.claims set status = 'expired' where status = 'open' and expires_at <= now();
end $function$;

CREATE OR REPLACE FUNCTION tracking.paused_count (
  p_account uuid
)
  RETURNS integer
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select count(*)::int from tracking.submissions s where s.social_account_id = p_account and s.status in ('tracking', 'flagged');
$function$;

CREATE OR REPLACE FUNCTION trust.apply_submission_decision (
  p_submission uuid,
  p_decision   text,
  p_actor      uuid,
  p_reason     text,
  p_message    text,
  p_note       text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  d jsonb := coalesce((select st.value from ops.settings st where st.key = 'trust.score_deltas'), '{}');
  d_ok int := coalesce((d ->> 'submission_approved')::int, 1);
  d_rej int := coalesce((d ->> 'submission_rejected')::int, -2);
  d_app int := coalesce((d ->> 'appeal_failed')::int, -3);
  to_status tracking.submission_status;
  logged text;
  delta int;
  score_reason text;
begin
  select * into s from tracking.submissions where id = p_submission for update;
  if s.id is null then
    perform market.fail('not_found:submission', null, 'P0002');
  end if;
  if s.status = 'in_review' and p_decision in ('approve', 'auto_approve') then
    to_status := 'tracking'; logged := p_decision; delta := d_ok; score_reason := 'submission_approved';
  elsif s.status = 'in_review' and p_decision = 'reject' then
    to_status := 'rejected'; logged := 'reject'; delta := d_rej; score_reason := 'submission_rejected';
  elsif s.status = 'appealed' and p_decision in ('overturn', 'approve') then
    -- banding diterima: hapus efek reject sebelumnya + bonus approve
    to_status := 'tracking'; logged := 'overturn'; delta := d_ok - d_rej; score_reason := 'submission_approved';
  elsif s.status = 'appealed' and p_decision in ('uphold', 'reject') then
    to_status := 'rejected_final'; logged := 'uphold'; delta := d_app; score_reason := 'appeal_failed';
  else
    perform market.fail('invalid_state:' || s.status, format('keputusan %s tidak berlaku untuk submisi %s', p_decision, s.status));
  end if;
  if to_status in ('rejected', 'rejected_final') and nullif(btrim(p_reason), '') is null then
    perform market.fail('invalid:reason', 'penolakan wajib alasan standar');
  end if;

  update tracking.submissions
     set status = to_status, next_poll_at = case when to_status = 'tracking' then now() else next_poll_at end
   where id = s.id;
  insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
  values ('submission', s.id, p_actor, logged, p_reason, p_message, p_note);
  if delta <> 0 then
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by)
    values (s.user_id, greatest(least(delta, 100), -100), score_reason, s.id::text, p_actor);
  end if;
  -- DS "notif selalu ada angka": approve + views, rate/1K, ±earning & perkiraan cair (finance.clip_estimate); reject + views.
  perform ops.enqueue_notification(s.user_id, case when to_status = 'tracking' then 'submission.approved' else 'submission.rejected' end,
                                   jsonb_build_object('submission_id', s.id, 'campaign_id', s.campaign_id,
                                                      'campaign_title', (select c.title from market.campaigns c where c.id = s.campaign_id),
                                                      'url', s.url, 'reason', p_reason,
                                                      'message', p_message, 'final', to_status = 'rejected_final',
                                                      'platform', s.platform, 'views', greatest(s.counted_views, coalesce(s.last_views, 0)))
                                   || case when to_status = 'tracking' then finance.clip_estimate(s.id) else '{}' end);
end $function$;

REVOKE ALL ON FUNCTION "finance"."clip_estimate"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."clip_estimate"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."clip_estimate"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."notify_payout_processing"(finance.payouts) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."notify_payout_processing"(finance.payouts) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."notify_payout_processing"(finance.payouts) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."payout_eta"(text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."payout_eta"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."payout_eta"(text) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."payout_notice"(finance.payouts, numeric) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."payout_notice"(finance.payouts, numeric) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."payout_notice"(finance.payouts, numeric) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."pending_amounts"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."pending_amounts"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."pending_amounts"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."wallet_amounts"(uuid, finance.earning_state) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."wallet_amounts"(uuid, finance.earning_state) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."wallet_amounts"(uuid, finance.earning_state) TO "postgres";

REVOKE ALL ON FUNCTION "market"."rate_per_1k"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."rate_per_1k"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."rate_per_1k"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."paused_count"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."paused_count"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."paused_count"(uuid) TO "postgres";
