SET local check_function_bodies = off;

ALTER TABLE "tracking"."submissions"
  ADD COLUMN "final_skipped" boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION api.skip_failed_snapshot (
  p_alert bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  a ops.alerts;
  v tracking.view_snapshots;
  s tracking.submissions;
begin
  if not ops.has_admin('admin_ops') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into a from ops.alerts x where x.id = p_alert and x.kind = 'tracking.apply_failed' and x.resolved_at is null for update;
  if not found or coalesce(a.payload ->> 'snapshot_id', '') !~ '^[0-9]+$' then
    raise exception 'not_found:alert' using errcode = 'P0002';
  end if;
  select * into v from tracking.view_snapshots x where x.id = (a.payload ->> 'snapshot_id')::bigint;
  if not found then
    raise exception 'not_found:snapshot' using errcode = 'P0002';
  end if;
  select * into s from tracking.submissions t where t.id = v.submission_id for update;
  -- snapshot tertunda paling awal, atau final yang sudah diproses tapi accrual saat lock gagal (lifecycle step lock, O1-4)
  if v.id is distinct from (select min(x.id) from tracking.view_snapshots x
                             where x.submission_id = s.id and x.id > coalesce(s.applied_snapshot_id, 0))
     and not (v.is_final and v.id <= coalesce(s.applied_snapshot_id, 0) and s.status = 'tracking') then
    raise exception 'invalid_state:not_next_pending' using errcode = 'P0001';
  end if;
  update tracking.submissions set applied_snapshot_id = greatest(coalesce(applied_snapshot_id, 0), v.id),
         final_skipped = final_skipped or v.is_final,
         status = case when status = 'tracking' then 'flagged'::tracking.submission_status else status end
   where id = s.id;
  perform trust.raise_flag('submission', s.id, 'FR-12', 50,
                           jsonb_build_object('snapshot_id', v.id, 'alert_id', a.id, 'error', a.payload ->> 'error'));
  update ops.alerts set resolved_at = now(), resolved_by = (select auth.uid()) where id = a.id;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'snapshot.skip', 'submission:' || s.id,
          jsonb_build_object('applied_snapshot_id', s.applied_snapshot_id, 'status', s.status),
          jsonb_build_object('applied_snapshot_id', greatest(coalesce(s.applied_snapshot_id, 0), v.id), 'final_skipped', v.is_final, 'alert_id', a.id));
end $function$;

CREATE OR REPLACE FUNCTION bus.apply_keys (
  p        jsonb,
  p_source text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  t regclass := to_regclass(p ->> 'table');
  pk text[];
  k jsonb;
begin
  if t is null then  -- penerima belum upgrade: tahan antrean (sama dengan apply_row)
    raise exception 'bus_no_table:%', p ->> 'table' using errcode = 'P0001';
  end if;
  if bus.accepts(p_source, p ->> 'table') is null then  -- bukan tabel yang direplikasi pengirim ke sini
    perform bus.reject(jsonb_build_object('reason', 'table', 'table', p ->> 'table', 'op', 'reconcile'));
    return;
  end if;
  insert into bus.reconcile_keys (source, tbl, epoch, key)
  select p_source, t::text, (p ->> 'epoch')::uuid, x from jsonb_array_elements(coalesce(p -> 'keys', '[]')) x
  on conflict do nothing;
  if not coalesce((p ->> 'last')::boolean, false) then
    return;
  end if;
  -- Daftar tidak lengkap (potongan dipangkas bus.prune saat antrean macet > 7 hari, atau dilewati bus.skip) → tidak ada yang
  -- dihapus; dilaporkan, jalankan reconcile ulang (O1-3).
  if (select count(*) from bus.reconcile_keys r where r.source = p_source and r.tbl = t::text and r.epoch = (p ->> 'epoch')::uuid)
     is distinct from (p ->> 'total')::bigint then
    perform bus.reject(jsonb_build_object('reason', 'reconcile_incomplete', 'table', t::text, 'total', p -> 'total'));
    delete from bus.reconcile_keys where source = p_source and tbl = t::text and epoch = (p ->> 'epoch')::uuid;
    return;
  end if;
  pk := bus.pk_columns(t);
  for k in execute format('select jsonb_build_object(%s) from %s x where not exists (select 1 from bus.reconcile_keys r
                             where r.source = $1 and r.tbl = $2 and r.epoch = $3 and r.key = jsonb_build_object(%1$s))',
                          (select string_agg(format('%L, x.%I', c, c), ', ') from unnest(pk) c), t)
             using p_source, t::text, (p ->> 'epoch')::uuid loop
    -- baris yang tidak boleh dihapus (append-only mis. view_snapshots, dirujuk catatan uang) dilaporkan, antrean jalan (O1-2)
    begin
      perform bus.apply_row(jsonb_build_object('table', t::text, 'op', 'delete', 'key', k), p_source);
    exception when others then
      perform bus.reject(jsonb_build_object('reason', 'reconcile_delete', 'table', t::text, 'key', k, 'error', sqlerrm));
    end;
  end loop;
  delete from bus.reconcile_keys where source = p_source and tbl = t::text and epoch = (p ->> 'epoch')::uuid;
end $function$;

CREATE OR REPLACE FUNCTION bus.reconcile (
  p_table  regclass,
  p_target text
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pk text[] := bus.pk_columns(p_table);
  ep uuid := gen_random_uuid();
  keys jsonb := '[]';
  r jsonb;
  n int := 0;
begin
  if not exists (select 1 from pg_trigger tg
                  cross join lateral unnest(array_remove(string_to_array(encode(tg.tgargs, 'escape'), '\000'), '')) a
                  where tg.tgrelid = p_table and tg.tgfoid = 'bus.replicate()'::regprocedure and split_part(a, ':', 1) = p_target) then
    raise exception 'bus_no_replica:%:%', p_table, p_target using errcode = 'P0001';
  end if;
  execute format('lock table %s in share mode', p_table);
  for r in execute format('select jsonb_build_object(%s) from %s t order by %s',
                          (select string_agg(format('%L, t.%I', k, k), ', ') from unnest(pk) k), p_table,
                          (select string_agg(format('t.%I', k), ', ') from unnest(pk) k)) loop
    keys := keys || jsonb_build_array(r);
    n := n + 1;
    if jsonb_array_length(keys) = 1000 then
      perform bus.emit(p_target, 'rep.keys', jsonb_build_object('table', p_table::text, 'epoch', ep, 'keys', keys, 'last', false));
      keys := '[]';
    end if;
  end loop;
  perform bus.emit(p_target, 'rep.keys', jsonb_build_object('table', p_table::text, 'epoch', ep, 'keys', keys, 'last', true, 'total', n));
  return n;
end $function$;

CREATE OR REPLACE FUNCTION market.run_lifecycle()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  grace interval := (ops.cfg('tracking.final_grace_hours', '72'))::numeric * interval '1 hour';
  active constant tracking.submission_status[] := array['validating', 'in_review', 'tracking', 'flagged', 'appealed']::tracking.submission_status[];
  r record;
  fin bigint;
  n int;
begin
  -- Suspend berdurasi yang sudah lewat → active lagi (sanksi tetap tercatat dengan until); entry point yang mensyaratkan
  -- status 'active' (submit, sosmed, org, notifikasi) tidak terkunci selamanya menunggu unsuspend manual (R75).
  update market.profiles set status = 'active', suspended_until = null where status = 'suspended' and suspended_until <= now();
  for r in update market.campaigns set status = 'live' where status = 'scheduled' and start_at <= now() returning id, org_id loop
    perform market.notify_org(r.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'campaign.live',
                              market.campaign_ref(r.id));
    perform market.announce_campaign(r.id);
  end loop;
  update market.campaigns set status = 'tracking' where status in ('live', 'paused') and submit_deadline <= now();
  perform finance.void_stale_addons();

  perform finance.finalize_settlements();

  for r in select s.id, s.posted_at + make_interval(days => c.view_window_days) as window_end, s.next_poll_at
             from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
            where s.status = 'tracking'
              and (s.posted_at + make_interval(days => c.view_window_days) <= now() or c.status in ('exhausted', 'settling', 'settled'))
            order by s.id
            for update of s skip locked loop
    select v.id into fin from tracking.view_snapshots v where v.submission_id = r.id and v.is_final;
    -- Snapshot final yang belum diproses apply_snapshot (hook replika gagal → alert, CX11): proses ulang lewat apply_snapshot
    -- (cek fraud + accrual + lock), bukan accrual langsung; masih gagal → tetap tracking (dicoba lagi run berikutnya) + alert.
    -- Penanda = applied_snapshot_id milik admin (last_snapshot_at replika creator tiba walau hook gagal, CL15/CX12); naik
    -- berurutan, jadi ≥ final = final sudah diproses (snapshot sesudah final bisa tiba saat replika status tertinggal, CX15).
    if fin is not null and not exists (select 1 from tracking.submissions t where t.id = r.id and t.applied_snapshot_id >= fin) then
      begin
        perform tracking.apply_snapshot(fin);
      exception when others then
        perform ops.raise_alert('tracking.apply_failed', 'critical',
                                jsonb_build_object('snapshot_id', fin, 'step', 'lifecycle', 'error', sqlerrm), interval '1 hour');
      end;
    -- Sudah diproses (mis. flagged saat snapshot final tiba, lalu flag diselesaikan) → accrual final + lock; final yang dilewati
    -- admin_ops (final_skipped) → lock tanpa accrual-nya. Accrual gagal → alert (bisa dilewati), submisi lain tetap jalan (O1-4).
    elsif fin is not null then
      begin
        if not (select t.final_skipped from tracking.submissions t where t.id = r.id) then
          perform finance.accrue_earnings(r.id, fin);
        end if;
        update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id and status = 'tracking';
      exception when others then
        perform ops.raise_alert('tracking.apply_failed', 'critical',
                                jsonb_build_object('snapshot_id', fin, 'step', 'lock', 'error', sqlerrm), interval '1 hour');
      end;
    -- Grace dihitung dari yang terakhir: akhir window atau masuk tracking (approve/overturn telat) → poll final sempat jalan (R69).
    -- Lock tanpa snapshot final hanya bila antrean creator → admin sudah melewati batas itu (ping creator yang dikirim sesudahnya
    -- sudah tiba, FIFO): bus macet bukan berarti snapshot final tidak ada — earning tidak dikunci dari data yang tertinggal.
    elsif greatest(r.window_end, coalesce((select max(d.created_at) from trust.review_decisions d
                                            where d.target_type = 'submission' and d.target_id = r.id
                                              and d.decision in ('approve', 'auto_approve', 'overturn')), r.window_end)) + grace
          < least(now(), coalesce((select p.pinged_at from ops.bus_peers p where p.source = 'creator'), '-infinity')) then
      update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id;
      perform ops.raise_alert('tracking.final_missing', 'warning', jsonb_build_object('submission_id', r.id));
    elsif r.next_poll_at is null or r.next_poll_at > now() + interval '1 hour' then
      update tracking.submissions set next_poll_at = now() where id = r.id;
    end if;
  end loop;

  -- Submisi dibuat di project creator dan tiba lewat bus (FIFO). Campaign yang tutup karena deadline baru settle setelah ping
  -- creator yang dikirim > 1 menit sesudah deadline tiba: semua submisi yang diterima creator sebelum deadline sudah di sini (R83-1).
  update market.campaigns c set status = 'settling'
   where c.status in ('tracking', 'exhausted')
     and (c.status <> 'tracking'
          or coalesce((select p.pinged_at from ops.bus_peers p where p.source = 'creator'), '-infinity') > c.submit_deadline + interval '1 minute')
     and not exists (select 1 from tracking.submissions s where s.campaign_id = c.id and s.status = any (active))
     and not exists (select 1 from finance.pool_settlements ps join finance.reward_pools rp on rp.id = ps.pool_id
                     where rp.campaign_id = c.id);
  for r in update market.campaigns c set status = 'settled'
            where c.status = 'settling'
              and not exists (select 1 from tracking.submissions s where s.campaign_id = c.id
                              and (s.status = any (active) or s.status = 'locked'))
            returning c.id, c.org_id loop
    perform market.notify_org(r.org_id, array['brand_owner', 'brand_manager', 'brand_finance']::market.org_role[], 'campaign.settled',
      market.campaign_ref(r.id) || jsonb_build_object('leftover',
        coalesce((select jsonb_agg(finance.amount_ref(rp.reward_type_id, finance.balance(finance.account('campaign_pool', rp.id, rp.reward_type_id)))
                                   || jsonb_build_object('pool_id', rp.id) order by rp.id)
                  from finance.reward_pools rp where rp.campaign_id = r.id), '[]')));
    perform finance.return_noncash_leftover(r.id);
  end loop;

  -- Kesehatan job tracking (F-A01): submisi macet (tracking.lagging_count, termasuk worker mati) → alert (maks satu per 6 jam).
  n := tracking.lagging_count();
  if n > 0 then
    perform ops.raise_alert('tracking.lag', 'warning', jsonb_build_object('overdue', n), interval '6 hours');
  end if;

  perform finance.retry_instant_payouts();
  perform trust.auto_approve_overdue();
end $function$;
SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.skip_failed_snapshot (
  p_alert bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  a ops.alerts;
  v tracking.view_snapshots;
  s tracking.submissions;
begin
  if not ops.has_admin('admin_ops') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into a from ops.alerts x where x.id = p_alert and x.kind = 'tracking.apply_failed' and x.resolved_at is null for update;
  if not found or coalesce(a.payload ->> 'snapshot_id', '') !~ '^[0-9]+$' then
    raise exception 'not_found:alert' using errcode = 'P0002';
  end if;
  select * into v from tracking.view_snapshots x where x.id = (a.payload ->> 'snapshot_id')::bigint;
  if not found then
    raise exception 'not_found:snapshot' using errcode = 'P0002';
  end if;
  select * into s from tracking.submissions t where t.id = v.submission_id for update;
  -- snapshot tertunda paling awal, atau final yang sudah diproses tapi accrual saat lock gagal (lifecycle step lock, O1-4)
  if v.id is distinct from (select min(x.id) from tracking.view_snapshots x
                             where x.submission_id = s.id and x.id > coalesce(s.applied_snapshot_id, 0))
     and not (v.is_final and v.id <= coalesce(s.applied_snapshot_id, 0) and s.status = 'tracking') then
    raise exception 'invalid_state:not_next_pending' using errcode = 'P0001';
  end if;
  update tracking.submissions set applied_snapshot_id = greatest(coalesce(applied_snapshot_id, 0), v.id),
         final_skipped = final_skipped or v.is_final,
         status = case when status = 'tracking' then 'flagged'::tracking.submission_status else status end
   where id = s.id;
  perform trust.raise_flag('submission', s.id, 'FR-12', 50,
                           jsonb_build_object('snapshot_id', v.id, 'alert_id', a.id, 'error', a.payload ->> 'error'));
  update ops.alerts set resolved_at = now(), resolved_by = (select auth.uid()) where id = a.id;
  -- Snapshot sesudahnya ikut gagal hanya karena menunggu yang ini: proses sekarang (berurutan), alert-nya yang sudah diproses
  -- ditutup — tidak ikut "dilewati" tanpa cek fraud/accrual (O1-C8). Masih gagal → alert-nya tetap terbuka.
  begin
    perform tracking.apply_snapshot(m) from (select max(x.id) m from tracking.view_snapshots x where x.submission_id = s.id and x.id > v.id) n
     where m is not null;
  exception when others then
    perform ops.raise_alert('tracking.apply_failed', 'critical', jsonb_build_object('submission_id', s.id, 'step', 'skip_retry', 'error', sqlerrm),
                            interval '1 hour');
  end;
  update ops.alerts x set resolved_at = now(), resolved_by = (select auth.uid())
   where x.kind = 'tracking.apply_failed' and x.resolved_at is null and x.payload ->> 'snapshot_id' ~ '^[0-9]+$'
     and (x.payload ->> 'snapshot_id')::bigint in (select y.id from tracking.view_snapshots y where y.submission_id = s.id
                                                    and y.id <= (select t.applied_snapshot_id from tracking.submissions t where t.id = s.id));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'snapshot.skip', 'submission:' || s.id,
          jsonb_build_object('applied_snapshot_id', s.applied_snapshot_id, 'status', s.status),
          jsonb_build_object('applied_snapshot_id', greatest(coalesce(s.applied_snapshot_id, 0), v.id), 'final_skipped', v.is_final, 'alert_id', a.id));
end $function$;

CREATE OR REPLACE FUNCTION bus.apply_row (
  p        jsonb,
  p_source text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  allowed text[] := bus.accepts(p_source, p ->> 'table');
  bad text[];
  t regclass;
  pk text[];
  cols text[];
  upd text;
  n int := 0;
  h regprocedure;
begin
  -- Hanya tabel & kolom yang dikirim pemiliknya (bus/accept.sql, dari trigger bus.replicate pengirim): secret bus satu peer
  -- yang bocor tidak bisa menulis tabel lain di sini (uang, sanksi) atau kolom milik penerima.
  t := to_regclass(p ->> 'table');
  if t is null then  -- tabel belum ada di sini: penerima belum upgrade → tahan antrean
    raise exception 'bus_no_table:%', p ->> 'table' using errcode = 'P0001';
  end if;
  if allowed is null then
    perform bus.reject(jsonb_build_object('reason', 'table', 'table', p ->> 'table', 'op', p ->> 'op'));
    return;
  end if;
  pk := bus.pk_columns(t);
  bad := array(select k from jsonb_object_keys(case when jsonb_typeof(p -> 'row') = 'object' then p -> 'row' else '{}' end) k
                where not k = any (allowed || pk));
  -- kolom yang belum ada di sini (pengirim sudah upgrade, penerima belum) → tahan antrean, bukan dibuang
  if exists (select 1 from unnest(bad) k where not exists (select 1 from pg_attribute a where a.attrelid = t and a.attname = k
                                                                                        and a.attnum > 0 and not a.attisdropped)) then
    raise exception 'bus_no_column:% %', p ->> 'table', bad::text using errcode = 'P0001';
  end if;
  -- kolom yang ada tapi di luar allowlist (milik penerima / dipensiunkan) dibuang, sisanya tetap diterapkan
  if cardinality(bad) > 0 then
    perform bus.reject(jsonb_build_object('reason', 'columns', 'table', p ->> 'table', 'columns', to_jsonb(bad)));
    p := jsonb_set(p, '{row}', (p -> 'row') - bad);
  end if;
  -- delete hanya untuk tabel yang seluruh kolomnya milik pengirim: baris campuran (mis. profil dengan status/sanksi admin, org
  -- dengan fee admin) yang dihapus lalu dikirim ulang akan mengembalikan kolom milik penerima ke default. Dilewati + alert (tidak
  -- raise): delete baris campuran di pengirim (mis. hapus manual) tidak boleh menahan antrean selamanya.
  if p ->> 'op' = 'delete' and exists (select 1 from pg_attribute a where a.attrelid = t and a.attnum > 0 and not a.attisdropped
                                                                    and not a.attname = any (allowed || pk)) then
    perform bus.reject(jsonb_build_object('reason', 'delete', 'table', p ->> 'table', 'key', p -> 'key'));
    return;
  end if;
  perform set_config('bus.applying', 'on', true);
  if p ->> 'op' = 'delete' then
    execute format('delete from %s x using jsonb_populate_record(null::%s, $1) k where %s', t, t,
                   (select string_agg(format('x.%1$I = k.%1$I', c), ' and ') from unnest(pk) c))
      using p -> 'key';
  else
    select array_agg(k) into cols from jsonb_object_keys(p -> 'row') k;
    select string_agg(format('%1$I = r.%1$I', c), ', ') into upd from unnest(cols) c where not c = any (pk);
    -- update dulu: baris dengan kolom milik sebagian (mis. status dari admin) tidak bisa lewat INSERT … ON CONFLICT (NOT NULL
    -- kolom lain dicek sebelum konflik). Baris belum ada → insert; kolom wajib lain tidak dikirim = baris milik project lain
    -- yang belum/tidak ada di sini → dilewati. Nilai sama persis (bus.resync) → tidak diubah dan hook tidak jalan: tabel
    -- append-only menolak UPDATE dan hook (accrual, keputusan) tidak boleh jalan dua kali.
    if upd is not null then
      execute format('update %1$s x set %2$s from jsonb_populate_record(null::%1$s, $1) r where %3$s and row(%4$s) is distinct from row(%5$s)',
                     t, upd, (select string_agg(format('x.%1$I = r.%1$I', c), ' and ') from unnest(pk) c),
                     (select string_agg(format('x.%I', c), ', ') from unnest(cols) c),
                     (select string_agg(format('r.%I', c), ', ') from unnest(cols) c))
        using p -> 'row';
      get diagnostics n = row_count;
    end if;
    if n = 0 then
      begin
        execute format('insert into %1$s (%2$s) select %2$s from jsonb_populate_record(null::%1$s, $1) on conflict (%3$s) do nothing',
                       t, (select string_agg(format('%I', c), ', ') from unnest(cols) c),
                       (select string_agg(format('%I', c), ', ') from unnest(pk) c))
          using p -> 'row';
        get diagnostics n = row_count;
      exception when not_null_violation then
        n := 0;
      when foreign_key_violation then
        -- Kiriman biasa: induk dari pengirim lain belum tiba → tahan antrean (dicoba lagi). Resync sesudah restore: induknya
        -- hilang bersama DB yang dipulihkan (mis. claim di admin untuk submisi creator) → dilaporkan, antrean jalan (O1-C3).
        if not coalesce((p ->> 'resync')::boolean, false) then
          raise;
        end if;
        perform bus.reject(jsonb_build_object('reason', 'orphan', 'table', p ->> 'table', 'key', p -> 'key', 'error', sqlerrm));
        n := 0;
      end;
      if n = 0 then
        perform set_config('bus.applying', 'off', true);
        return;
      end if;
    end if;
  end if;
  perform set_config('bus.applying', 'off', true);
  h := to_regprocedure(format('bus_in.%s_%s_applied(text, jsonb)', split_part(p ->> 'table', '.', 1), split_part(p ->> 'table', '.', 2)));
  if h is not null then
    execute format('select %s($1, $2)', h::regproc) using p ->> 'op', coalesce(p -> 'row', p -> 'key');
  end if;
end $function$;

CREATE OR REPLACE FUNCTION bus.relay()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  t text;
  rid bigint;
  asked timestamptz;
  resp record;
  first_ready boolean;
  head_tries int;
  ids bigint[];
  events jsonb;
  body jsonb;
  ts text;
  url text;
  secret text;
  sent int := 0;
begin
  for t in select distinct o.target from bus.outbox o where o.sent_at is null order by 1 loop
    continue when not pg_try_advisory_xact_lock(hashtextextended('bus_relay:' || t, 0));
    select o.request_id, o.requested_at into rid, asked
      from bus.outbox o where o.target = t and o.sent_at is null and o.request_id is not null order by o.seq limit 1;
    if rid is not null then
      select r.status_code, r.timed_out, r.error_msg, left(r.content, 500) as content into resp
        from net._http_response r where r.id = rid;
      if found and resp.status_code = 200 then
        update bus.outbox set sent_at = now(), last_error = null where target = t and request_id = rid;
      elsif found or asked < now() - interval '60 seconds' then
        update bus.outbox
           set request_id = null, requested_at = null, attempts = attempts + 1,
               next_at = now() + least(interval '1 hour', interval '5 seconds' * power(2, least(attempts, 10))),
               last_error = coalesce(resp.error_msg, case when resp.timed_out then 'timeout' end,
                                     'http ' || resp.status_code || ' ' || coalesce(resp.content, ''), 'no response')
         where target = t and request_id = rid;
        continue;
      else
        continue;  -- masih menunggu jawaban
      end if;
    end if;
    select o.next_at <= now(), o.attempts into first_ready, head_tries
      from bus.outbox o where o.target = t and o.sent_at is null order by o.seq limit 1;
    continue when not coalesce(first_ready, false);
    select array_agg(b.seq order by b.seq), jsonb_agg(jsonb_build_object('id', b.id, 'topic', b.topic, 'payload', b.payload) order by b.seq)
      into ids, events
      from (select o.seq, o.id, o.topic, o.payload from bus.outbox o
             where o.target = t and o.sent_at is null order by o.seq
             -- gagal ≥ 3 kali → satu per satu: error penerima tidak menyebut event mana, jadi kepala = event yang gagal
             -- (bus.skip tepat sasaran, O1-C6)
             limit case when head_tries >= 3 then 1 else 100 end) b;
    select ds.decrypted_secret into url from vault.decrypted_secrets ds where ds.name = 'bus_url_' || t;
    select ds.decrypted_secret into secret from vault.decrypted_secrets ds where ds.name = 'bus_secret_' || t;
    if url is null or secret is null then
      update bus.outbox set last_error = 'vault bus_url_/bus_secret_' || t || ' belum diisi' where seq = any (ids);
      continue;
    end if;
    body := jsonb_build_object('v', 1, 'action', 'bus.deliver', 'payload', jsonb_build_object('source', bus.me(), 'events', events));
    ts := floor(extract(epoch from now()))::bigint::text;
    rid := net.http_post(
      url := url || '/functions/v1/bridge',
      body := body,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-bridge-ts', ts, 'x-bridge-from', bus.me(),
                                    'x-bridge-sig', encode(extensions.hmac(ts || '.' || body::text, secret, 'sha256'), 'hex')),
      timeout_milliseconds := 15000);
    update bus.outbox set request_id = rid, requested_at = now() where seq = any (ids);
    sent := sent + cardinality(ids);
  end loop;
  return sent;
end $function$;

CREATE OR REPLACE FUNCTION bus.resync (
  p_table  regclass,
  p_target text
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  cols text[];
  pk text[] := bus.pk_columns(p_table);
  r jsonb;
  n int := 0;
begin
  select string_to_array(split_part(a, ':', 2), ',') into cols
    from pg_trigger tg
   cross join lateral unnest(array_remove(string_to_array(encode(tg.tgargs, 'escape'), '\000'), '')) a
   where tg.tgrelid = p_table and tg.tgfoid = 'bus.replicate()'::regprocedure and split_part(a, ':', 1) = p_target;
  if cols is null then
    raise exception 'bus_no_replica:%:%', p_table, p_target using errcode = 'P0001';
  end if;
  -- Tulisan baru menunggu sampai resync commit: event resync (snapshot lama) tidak bisa menyalip event tulisan yang lebih baru (R83-2).
  execute format('lock table %s in share mode', p_table);
  -- urut kunci primer: penerima memproses berurutan (mis. snapshot — apply_snapshot menganggap id ≤ penanda sudah diproses, CX16)
  for r in execute format('select to_jsonb(t) from %s t order by %s', p_table,
                          (select string_agg(format('t.%I', k), ', ') from unnest(pk) k)) loop
    perform bus.emit(p_target, 'rep.row', jsonb_build_object('table', p_table::text, 'op', 'upsert', 'resync', true,
      'key', (select jsonb_object_agg(k, r -> k) from unnest(pk) k),
      'row', (select jsonb_object_agg(c, r -> c) from unnest(cols || pk) c)));
    n := n + 1;
  end loop;
  return n;
end $function$;
SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION market.run_lifecycle()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  grace interval := (ops.cfg('tracking.final_grace_hours', '72'))::numeric * interval '1 hour';
  active constant tracking.submission_status[] := array['validating', 'in_review', 'tracking', 'flagged', 'appealed']::tracking.submission_status[];
  r record;
  fin bigint;
  e text;
  step text;
  n int;
begin
  -- Suspend berdurasi yang sudah lewat → active lagi (sanksi tetap tercatat dengan until); entry point yang mensyaratkan
  -- status 'active' (submit, sosmed, org, notifikasi) tidak terkunci selamanya menunggu unsuspend manual (R75).
  update market.profiles set status = 'active', suspended_until = null where status = 'suspended' and suspended_until <= now();
  for r in update market.campaigns set status = 'live' where status = 'scheduled' and start_at <= now() returning id, org_id loop
    perform market.notify_org(r.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'campaign.live',
                              market.campaign_ref(r.id));
    perform market.announce_campaign(r.id);
  end loop;
  update market.campaigns set status = 'tracking' where status in ('live', 'paused') and submit_deadline <= now();
  perform finance.void_stale_addons();

  perform finance.finalize_settlements();

  for r in select s.id, s.posted_at + make_interval(days => c.view_window_days) as window_end, s.next_poll_at
             from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
            where s.status = 'tracking'
              and (s.posted_at + make_interval(days => c.view_window_days) <= now() or c.status in ('exhausted', 'settling', 'settled'))
            order by s.id
            for update of s skip locked loop
    select v.id into fin from tracking.view_snapshots v where v.submission_id = r.id and v.is_final;
    e := null;
    -- Snapshot final yang belum diproses apply_snapshot (hook replika gagal → alert, CX11): proses ulang lewat apply_snapshot
    -- (cek fraud + accrual + lock), bukan accrual langsung; masih gagal → tetap tracking (dicoba lagi run berikutnya) + alert.
    -- Penanda = applied_snapshot_id milik admin (last_snapshot_at replika creator tiba walau hook gagal, CL15/CX12); naik
    -- berurutan, jadi ≥ final = final sudah diproses (snapshot sesudah final bisa tiba saat replika status tertinggal, CX15).
    if fin is not null and not exists (select 1 from tracking.submissions t where t.id = r.id and t.applied_snapshot_id >= fin) then
      begin
        perform tracking.apply_snapshot(fin);
      exception when others then
        e := sqlerrm;
        step := 'lifecycle';
      end;
    -- Sudah diproses (mis. flagged saat snapshot final tiba, lalu flag diselesaikan) → accrual final + lock; final yang dilewati
    -- admin_ops (final_skipped) → lock tanpa accrual-nya. Accrual gagal → alert (bisa dilewati), submisi lain tetap jalan (O1-4).
    elsif fin is not null then
      begin
        if not (select t.final_skipped from tracking.submissions t where t.id = r.id) then
          perform finance.accrue_earnings(r.id, fin);
        end if;
        update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id and status = 'tracking';
      exception when others then
        e := sqlerrm;
        step := 'lock';
      end;
    -- Grace dihitung dari yang terakhir: akhir window atau masuk tracking (approve/overturn telat) → poll final sempat jalan (R69).
    -- Lock tanpa snapshot final hanya bila antrean creator → admin sudah melewati batas itu (ping creator yang dikirim sesudahnya
    -- sudah tiba, FIFO): bus macet bukan berarti snapshot final tidak ada — earning tidak dikunci dari data yang tertinggal.
    elsif greatest(r.window_end, coalesce((select max(d.created_at) from trust.review_decisions d
                                            where d.target_type = 'submission' and d.target_id = r.id
                                              and d.decision in ('approve', 'auto_approve', 'overturn')), r.window_end)) + grace
          < least(now(), coalesce((select p.pinged_at from ops.bus_peers p where p.source = 'creator'), '-infinity')) then
      update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id;
      perform ops.raise_alert('tracking.final_missing', 'warning', jsonb_build_object('submission_id', r.id));
    elsif r.next_poll_at is null or r.next_poll_at > now() + interval '1 hour' then
      update tracking.submissions set next_poll_at = now() where id = r.id;
    end if;
    -- satu alert terbuka per snapshot (bukan dedupe per jenis): tiap snapshot macet punya tombol "Lewati snapshot" sendiri
    if e is not null and not exists (select 1 from ops.alerts a where a.kind = 'tracking.apply_failed' and a.resolved_at is null
                                                                and a.payload ->> 'snapshot_id' = fin::text) then
      perform ops.raise_alert('tracking.apply_failed', 'critical', jsonb_build_object('snapshot_id', fin, 'step', step, 'error', e));
    end if;
  end loop;

  -- Submisi dibuat di project creator dan tiba lewat bus (FIFO). Campaign yang tutup karena deadline baru settle setelah ping
  -- creator yang dikirim > 1 menit sesudah deadline tiba: semua submisi yang diterima creator sebelum deadline sudah di sini (R83-1).
  update market.campaigns c set status = 'settling'
   where c.status in ('tracking', 'exhausted')
     and (c.status <> 'tracking'
          or coalesce((select p.pinged_at from ops.bus_peers p where p.source = 'creator'), '-infinity') > c.submit_deadline + interval '1 minute')
     and not exists (select 1 from tracking.submissions s where s.campaign_id = c.id and s.status = any (active))
     and not exists (select 1 from finance.pool_settlements ps join finance.reward_pools rp on rp.id = ps.pool_id
                     where rp.campaign_id = c.id);
  for r in update market.campaigns c set status = 'settled'
            where c.status = 'settling'
              and not exists (select 1 from tracking.submissions s where s.campaign_id = c.id
                              and (s.status = any (active) or s.status = 'locked'))
            returning c.id, c.org_id loop
    perform market.notify_org(r.org_id, array['brand_owner', 'brand_manager', 'brand_finance']::market.org_role[], 'campaign.settled',
      market.campaign_ref(r.id) || jsonb_build_object('leftover',
        coalesce((select jsonb_agg(finance.amount_ref(rp.reward_type_id, finance.balance(finance.account('campaign_pool', rp.id, rp.reward_type_id)))
                                   || jsonb_build_object('pool_id', rp.id) order by rp.id)
                  from finance.reward_pools rp where rp.campaign_id = r.id), '[]')));
    perform finance.return_noncash_leftover(r.id);
  end loop;

  -- Kesehatan job tracking (F-A01): submisi macet (tracking.lagging_count, termasuk worker mati) → alert (maks satu per 6 jam).
  n := tracking.lagging_count();
  if n > 0 then
    perform ops.raise_alert('tracking.lag', 'warning', jsonb_build_object('overdue', n), interval '6 hours');
  end if;

  perform finance.retry_instant_payouts();
  perform trust.auto_approve_overdue();
end $function$;
