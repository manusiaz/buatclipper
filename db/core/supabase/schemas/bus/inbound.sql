-- Handler event masuk ke admin (konvensi bus.sql: topic 'a.b' → bus_in.a_b(jsonb)). Pengirim sudah diverifikasi HMAC di bridge;
-- payload = data dari project pemilik, bukan sesi user. Gagal → seluruh batch diulang pengirim (idempoten lewat bus.inbox).

-- Pusat audit (ops.audit_logs append-only): salinan baris audit project lain, waktu asli dipertahankan.
create function bus_in.audit_log(p jsonb) returns void
language sql set search_path = '' as $$
  insert into ops.audit_logs (actor_id, action, target, before, after, at)
  select r.actor_id, r.action, r.target, r.before, r.after, coalesce(r.at, now()) from jsonb_populate_record(null::ops.audit_logs, p) r;
$$;

-- E-19 keputusan review yang diambil di project lain (mis. verifikasi org di brand).
create function bus_in.review_decision(p jsonb) returns void
language sql set search_path = '' as $$
  insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
  select r.target_type, r.target_id, r.actor_id, r.decision, r.reason_code, r.message, r.note
    from jsonb_populate_record(null::trust.review_decisions, p) r;
$$;

-- Inbox & pengiriman email/push satu pintu di admin. Undangan campaign dilengkapi rate per 1.000 views (rule milik admin).
create function bus_in.notify_user(p jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  body jsonb := coalesce(p -> 'payload', '{}');
begin
  if p ->> 'event' = 'campaign.invited' and body ? 'campaign_id' then
    body := body || jsonb_build_object('rate_per_1k', market.rate_per_1k((body ->> 'campaign_id')::uuid));
  end if;
  perform ops.enqueue_notification((p ->> 'user_id')::uuid, p ->> 'event', body, coalesce((p ->> 'email')::boolean, true));
end $$;

-- Referral (F-C16) dari profil baru di project creator: kode milik admin (market.profiles.referral_code); kode tidak dikenal
-- atau milik sendiri diabaikan. Replika profil yang dirujuk tiba lebih dulu (event dikirim setelah insert profil, satu sumber).
create function bus_in.referral_record(p jsonb) returns void
language sql set search_path = '' as $$
  insert into market.referrals (referred_id, referrer_id, code)
  select (p ->> 'user_id')::uuid, r.id, r.referral_code from market.profiles r
   where r.referral_code = p ->> 'code' and r.id <> (p ->> 'user_id')::uuid
  on conflict do nothing;
$$;

-- Owner org dikeluarkan/diturunkan di brand (R25-1/R26-1): refund yang memakai rekening pribadinya dikosongkan + persetujuannya
-- batal (owner sekarang memilih ulang), kecuali transfernya sudah dimulai. Baris anggota (replika, masih ada: event ini dikirim
-- sebelum replikanya) dikunci dulu = urutan kunci sama dengan set_refund_destination / export bridge → tanpa deadlock (R26-2).
create function bus_in.org_owner_lost(p jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  v_org uuid := (p ->> 'org_id')::uuid;
  v_user uuid := (p ->> 'user_id')::uuid;
begin
  perform 1 from market.org_members m where m.org_id = v_org and m.user_id = v_user for update;
  with r as (
    update finance.org_refunds x
       set dest_set_by = null, status = 'requested', approved_by = null
     where x.org_id = v_org and x.dest_set_by = v_user and x.dest_account is null
       and (x.status = 'requested' or (x.status = 'approved' and x.transfer_started_at is null))
    returning x.id)
  insert into ops.audit_logs (actor_id, action, target, after)
  select (p ->> 'actor_id')::uuid, 'refund.dest_reset', 'refund:' || r.id, jsonb_build_object('reason', 'owner_lost', 'user_id', v_user)
    from r;
end $$;

revoke execute on function bus_in.audit_log(jsonb), bus_in.review_decision(jsonb), bus_in.notify_user(jsonb),
  bus_in.referral_record(jsonb), bus_in.org_owner_lost(jsonb) from public;
