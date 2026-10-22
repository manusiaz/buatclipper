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

-- Inbox & pengiriman email/push satu pintu di admin.
create function bus_in.notify_user(p jsonb) returns void
language plpgsql set search_path = '' as $$
begin
  perform ops.enqueue_notification((p ->> 'user_id')::uuid, p ->> 'event', coalesce(p -> 'payload', '{}'),
                                   coalesce((p ->> 'email')::boolean, true));
end $$;

-- Profil minimal anggota brand yang belum onboarding; dikirim brand sebelum replika anggotanya (FK org_members → profiles).
create function bus_in.profile_ensure(p jsonb) returns void
language plpgsql set search_path = '' as $$
begin
  perform market.ensure_member_profile((p ->> 'user_id')::uuid, p ->> 'username', p ->> 'display_name');
end $$;

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
  bus_in.profile_ensure(jsonb), bus_in.org_owner_lost(jsonb) from public;
