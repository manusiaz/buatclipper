-- RPC service_role untuk Edge Function core/bridge: panggilan dari identity (alur 3, 6, 7, 9, 10, 11) yang sudah diverifikasi
-- tanda tangan HMAC-nya di Edge Function. EXECUTE hanya untuk service_role.

-- Alur 3: isi batch yang sudah disetujui dua orang (approved_by ≠ created_by) untuk dibuat CSV di identity.
-- amount = bruto yang dipotong dari Tersedia; yang ditransfer = amount − fee.
create function api.bridge_get_batch(p_batch uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  b finance.payout_batches;
begin
  select * into b from finance.payout_batches x where x.id = p_batch;
  if not found then
    raise exception 'not_found:batch' using errcode = 'P0002';
  end if;
  if b.status not in ('approved', 'exported') then  -- exported: identity menandatangani ulang link berkas yang sama
    raise exception 'invalid_state:%', b.status using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'batch', jsonb_build_object('id', b.id, 'status', b.status, 'created_by', b.created_by, 'approved_by', b.approved_by,
                                'file_ref', b.file_ref),
    -- blocked: profil di-ban/suspend atau flag fraud terbuka sejak batch disetujui → identity menahannya (bukan masuk CSV).
    'payouts', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'user_id', p.user_id, 'method_id', p.method_id,
                                                             'amount', p.amount, 'fee', p.fee,
                                                             'blocked', finance.payout_block(p.user_id, p.id)) order by p.id)
                         from finance.payouts p where p.batch_id = b.id and p.status = 'requested'), '[]'));
end $$;

-- Alur 3: CSV jadi. Payout yang gagal cek (pemilik/nama rekening) → on_hold dengan alasan; sisanya processing (masuk CSV).
-- p_exported = payout yang benar-benar ada di CSV. Isi DB bisa berubah sejak get_batch (batal, tahan fraud): kalau tidak
-- cocok → export_stale, CSV tidak diserahkan (identity menghapus berkasnya) dan admin mengekspor ulang.
create function api.bridge_attach_export(p_batch uuid, p_file_ref text, p_held jsonb, p_exported uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
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
end $$;

-- Alur 9: bukti transfer. batch: proof_ref ke payout paid, batch → closed. refund: E-35 dibayar + jurnal (finance.pay_refund).
create function api.bridge_attach_proof(p_target text, p_id uuid, p_proof_ref text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st text;
begin
  if p_proof_ref is null or btrim(p_proof_ref) = '' then
    raise exception 'invalid:proof_ref' using errcode = 'P0001';
  end if;
  if p_target = 'batch' then
    select b.status into st from finance.payout_batches b where b.id = p_id for update;
    if st is null then
      raise exception 'not_found:batch' using errcode = 'P0002';
    end if;
    if st not in ('paid', 'closed') then
      raise exception 'invalid_state:%', st using errcode = 'P0001';
    end if;
    update finance.payouts set proof_ref = p_proof_ref where batch_id = p_id and status = 'paid';
    update finance.payout_batches set status = 'closed' where id = p_id;
  elsif p_target = 'refund' then
    perform finance.pay_refund(p_id, p_proof_ref);
  else
    raise exception 'invalid:target' using errcode = 'P0001';
  end if;
end $$;

-- Alur 6: sinyal fraud dari identity (FR-04 NIK/rekening ganda, FR-05 device/IP sama).
create function api.bridge_raise_fraud_flag(p_target_type text, p_target_id uuid, p_signal text, p_score numeric, p_details jsonb)
returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  return trust.raise_flag(p_target_type, p_target_id, p_signal, p_score, p_details);
end $$;

-- Alur 7 (UU PDP): tutup akun dalam satu transaksi. Ditolak kalau masih ada saldo pending/Tersedia atau payout/fulfillment
-- berjalan. Akun sosmed yang pernah dipakai submisi tidak bisa dihapus (FK riwayat earning) → token Vault dihapus, akun
-- diputus & handle dianonimkan; yang belum pernah dipakai dihapus. Ledger tetap utuh.
create function api.bridge_close_account(p_user uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  pr market.profiles;
begin
  select * into pr from market.profiles p where p.id = p_user for update;
  if not found then
    return jsonb_build_object('ok', true, 'reason', 'no_profile');
  end if;
  if pr.status = 'closed' then
    return jsonb_build_object('ok', true, 'reason', 'already_closed');
  end if;
  if exists (select 1 from finance.ledger_accounts a join finance.ledger_entries e on e.account_id = a.id
             where a.owner_type = 'user_wallet' and a.owner_id = p_user and e.state in ('pending', 'available')
             group by a.id, e.state having sum(e.amount) <> 0) then
    return jsonb_build_object('ok', false, 'reason', 'balance_remaining');
  end if;
  if exists (select 1 from finance.payouts p where p.user_id = p_user and p.status in ('requested', 'on_hold', 'processing', 'failed')) then
    return jsonb_build_object('ok', false, 'reason', 'payout_in_progress');
  end if;
  if exists (select 1 from finance.fulfillments f where f.user_id = p_user and f.status in ('requested', 'on_hold', 'processing', 'failed')) then
    return jsonb_build_object('ok', false, 'reason', 'fulfillment_in_progress');
  end if;

  update tracking.submissions set status = 'forfeited', next_poll_at = null where user_id = p_user and status in ('tracking', 'flagged');
  update tracking.submissions set status = 'rejected' where user_id = p_user and status in ('validating', 'in_review');
  update tracking.submissions set status = 'rejected_final' where user_id = p_user and status = 'appealed';
  update market.claims set status = 'released' where user_id = p_user and status = 'open';
  delete from vault.secrets v where v.id in (select a.token_ref from tracking.social_accounts a where a.user_id = p_user);
  delete from tracking.social_accounts a
   where a.user_id = p_user and not exists (select 1 from tracking.submissions s where s.social_account_id = a.id);
  update tracking.social_accounts set status = 'disconnected', token_ref = null, handle = 'deleted', followers = null
   where user_id = p_user;
  update market.profiles set username = 'deleted_' || substr(md5(id::text), 1, 12), display_name = 'Akun dihapus',
         avatar_path = null, referral_code = null, suspended_until = null, status = 'closed'
   where id = p_user;
  return jsonb_build_object('ok', true, 'reason', null);
end $$;

-- Alur 11: data payout instant untuk disburse (transfer = net_amount = amount − fee).
create function api.bridge_get_payout(p_payout uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  p finance.payouts;
begin
  select * into p from finance.payouts x where x.id = p_payout;
  if not found then
    raise exception 'not_found:payout' using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', p.id, 'user_id', p.user_id, 'method_id', p.method_id, 'amount', p.amount, 'fee', p.fee,
                            'net_amount', p.amount - p.fee, 'channel', p.channel, 'status', p.status, 'provider_ref', p.provider_ref);
end $$;

-- AB-6: refund org perorangan → identity membuka rekening bank pribadi dest_set_by (pemilik org) untuk transfer.
create function api.bridge_get_refund(p_refund uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  r finance.org_refunds;
begin
  select * into r from finance.org_refunds x where x.id = p_refund;
  if not found then
    raise exception 'not_found:refund' using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', r.id, 'status', r.status, 'requested_by', r.requested_by, 'approved_by', r.approved_by,
                            'dest_set_by', r.dest_set_by, 'company_account', r.dest_account is not null, 'amount', r.amount,
                            'fee', r.transfer_fee,
                            'dest_owner_current', exists (select 1 from market.org_members m where m.org_id = r.org_id
                                                            and m.user_id = r.dest_set_by and m.role = 'brand_owner'));
end $$;

-- R26-1: rekening pribadi refund dibuka untuk transfer = transfer dimulai. Dicatat sebelum identity menampilkan rekening;
-- ditolak kalau persetujuan/tujuan berubah atau pemilik rekening sudah bukan owner org.
create function api.bridge_refund_revealed(p_refund uuid, p_dest_set_by uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r finance.org_refunds;
begin
  select * into r from finance.org_refunds x where x.id = p_refund;
  if not found then
    raise exception 'not_found:refund' using errcode = 'P0002';
  end if;
  -- anggota dikunci sebelum refund (urutan sama dengan hapus owner → trigger on_owner_lost): tanpa deadlock
  if not market.is_direct_member(r.org_id, p_dest_set_by, 'brand_owner') then
    raise exception 'refund_dest_invalid' using errcode = 'P0001', detail = 'pemilik rekening bukan owner org lagi';
  end if;
  select * into r from finance.org_refunds x where x.id = p_refund for update;
  if r.status <> 'approved' or r.dest_account is not null or r.dest_set_by is distinct from p_dest_set_by then
    raise exception 'refund_dest_invalid' using errcode = 'P0001', detail = 'tujuan atau persetujuan refund berubah';
  end if;
  update finance.org_refunds set transfer_started_at = coalesce(transfer_started_at, now()) where id = r.id;
end $$;

-- Alur 11: hasil penyedia disbursement. provider_ref UNIQUE (satu payout = satu transfer); failed → dana + fee kembali ke
-- Tersedia (finance.return_payout). Status yang sama dikirim ulang = no-op.
create function api.bridge_mark_instant(p_payout uuid, p_status text, p_provider_ref text, p_error text) returns void
language plpgsql security definer set search_path = '' as $$
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
end $$;

-- Alur 9: rekap bruto payout terbayar per clipper (dasar PPh 21), rentang tanggal WIB inklusif.
-- §5.4: penghasilan bruto clipper per periode (WIB) = payout tunai dibayar + reward non-tunai terkirim dinilai Rupiah
-- (idr_value_per_unit reward type saat ini). Tarif PPh 21 tidak dihitung di sini (keputusan tim pajak).
create function api.bridge_pph21(p_from date, p_to date) returns table (user_id uuid, cash numeric, noncash numeric, gross numeric)
language plpgsql stable security definer set search_path = '' as $$
declare
  t0 timestamptz := p_from::timestamp at time zone 'Asia/Jakarta';
  t1 timestamptz := (p_to + 1)::timestamp at time zone 'Asia/Jakarta';
begin
  return query
  select x.user_id, sum(x.cash), sum(x.noncash), sum(x.cash + x.noncash)
    from (select p.user_id, p.amount::numeric as cash, 0::numeric as noncash from finance.payouts p
           where p.status = 'paid' and p.paid_at >= t0 and p.paid_at < t1
          union all
          select f.user_id, 0, round(f.amount * rt.idr_value_per_unit, 2) from finance.fulfillments f
            join market.reward_types rt on rt.id = f.reward_type_id
           where f.status = 'delivered' and f.delivered_at >= t0 and f.delivered_at < t1) x
   group by x.user_id order by x.user_id;
end $$;

-- Alur 3 (reward fisik/manual_export): klaim yang menunggu export ke brand. Hanya baca; data PII penerima ada di identity.
create function api.bridge_fulfillment_export(p_reward_type uuid)
returns table (id uuid, user_id uuid, amount numeric, recipient jsonb, recipient_ref uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  return query
  select f.id, f.user_id, f.amount::numeric, f.recipient, f.recipient_ref
    from finance.fulfillments f join market.reward_types rt on rt.id = f.reward_type_id
   where f.reward_type_id = p_reward_type and f.status = 'requested' and rt.fulfillment = 'manual_export'
     and not finance.withdraw_blocked(f.user_id)
   order by f.created_at, f.id;
end $$;

-- Serah-terima CSV penerima ke brand: klaim yang ada di berkas → processing + export_ref (tidak terekspor ulang; refund butuh
-- konfirmasi brand). Klaim yang berubah sejak dibaca → export_stale, berkas tidak diserahkan. Kirim ulang berkas yang sama
-- (respons hilang, bridge mencoba lagi) = no-op.
create function api.bridge_attach_fulfillment_export(p_reward_type uuid, p_file_ref text, p_exported uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_file_ref is null or btrim(p_file_ref) = '' then
    raise exception 'invalid:file_ref' using errcode = 'P0001';
  end if;
  perform 1 from finance.fulfillments f where f.id = any (coalesce(p_exported, '{}')) order by f.id for update;
  if exists (select 1 from unnest(coalesce(p_exported, '{}')) e(id)
              where not exists (select 1 from finance.fulfillments f join market.reward_types rt on rt.id = f.reward_type_id
                                 where f.id = e.id and f.reward_type_id = p_reward_type and rt.fulfillment = 'manual_export'
                                   and (f.status = 'requested' or f.export_ref = p_file_ref))) then
    raise exception 'export_stale' using errcode = 'P0001', detail = 'klaim berubah sejak dibaca; ekspor ulang';
  end if;
  update finance.fulfillments set status = 'processing', export_ref = p_file_ref where id = any (p_exported) and status = 'requested';
end $$;

-- Unduh ulang CSV penerima: identity hanya menandatangani berkas yang benar-benar diterima core untuk reward type itu.
create function api.bridge_fulfillment_export_accepted(p_reward_type uuid, p_file_ref text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from finance.fulfillments f where f.reward_type_id = p_reward_type and f.export_ref = p_file_ref);
$$;

-- F-X01: email alert terkirim ke admin (bridge cron notify_admins sukses) → batas 1 email/jenis/jam mulai dihitung.
create function api.bridge_alert_notified(p_alert bigint) returns void
language sql security definer set search_path = '' as $$
  update ops.alerts set notified_at = now() where id = p_alert and notified_at is null;
$$;

-- FR-05 (§12 "semua ambang di config"): identity membaca jendela & minimum akun per perangkat sebelum scan sesi login.
create function api.bridge_fraud_device_params() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('window_hours', (ops.cfg('trust.fraud.shared_device_window_hours', '24'))::int,
                            'min_accounts', (ops.cfg('trust.fraud.shared_device_min_accounts', '3'))::int);
$$;

-- Alur 10: ID lintas DB yang dirujuk core (profil belum ditutup, rekening & penerima milik mereka).
create function api.bridge_collect_ids() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  return jsonb_build_object(
    'user_ids', coalesce((select jsonb_agg(p.id order by p.id) from market.profiles p where p.status <> 'closed'), '[]'),
    'method_ids', coalesce((select jsonb_agg(distinct x.method_id) from finance.payouts x
                            join market.profiles p on p.id = x.user_id where p.status <> 'closed'), '[]'),
    'recipient_refs', coalesce((select jsonb_agg(distinct f.recipient_ref) from finance.fulfillments f
                                join market.profiles p on p.id = f.user_id
                                where f.recipient_ref is not null and p.status <> 'closed'), '[]'));
end $$;

-- Alur 10: ID yang tidak ada lagi di identity → alert antrean review finance.
create function api.bridge_report_orphans(p_missing jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from jsonb_each(coalesce(p_missing, '{}')) e
             where jsonb_typeof(e.value) = 'array' and jsonb_array_length(e.value) > 0) then
    perform ops.raise_alert('reconcile.orphans', 'critical', p_missing);
  end if;
end $$;

revoke execute on function api.bridge_get_batch(uuid), api.bridge_attach_export(uuid, text, jsonb, uuid[]),
  api.bridge_attach_fulfillment_export(uuid, text, uuid[]), api.bridge_fulfillment_export_accepted(uuid, text),
  api.bridge_attach_proof(text, uuid, text), api.bridge_raise_fraud_flag(text, uuid, text, numeric, jsonb),
  api.bridge_close_account(uuid), api.bridge_get_payout(uuid), api.bridge_mark_instant(uuid, text, text, text),
  api.bridge_pph21(date, date), api.bridge_fulfillment_export(uuid), api.bridge_collect_ids(), api.bridge_report_orphans(jsonb),
  api.bridge_alert_notified(bigint), api.bridge_get_refund(uuid), api.bridge_refund_revealed(uuid, uuid), api.bridge_fraud_device_params()
  from public, anon, authenticated;
grant execute on function api.bridge_get_batch(uuid), api.bridge_attach_export(uuid, text, jsonb, uuid[]),
  api.bridge_attach_fulfillment_export(uuid, text, uuid[]), api.bridge_fulfillment_export_accepted(uuid, text),
  api.bridge_attach_proof(text, uuid, text), api.bridge_raise_fraud_flag(text, uuid, text, numeric, jsonb),
  api.bridge_close_account(uuid), api.bridge_get_payout(uuid), api.bridge_mark_instant(uuid, text, text, text),
  api.bridge_pph21(date, date), api.bridge_fulfillment_export(uuid), api.bridge_collect_ids(), api.bridge_report_orphans(jsonb),
  api.bridge_alert_notified(bigint), api.bridge_get_refund(uuid), api.bridge_refund_revealed(uuid, uuid), api.bridge_fraud_device_params()
  to service_role;
