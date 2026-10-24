-- Handler event masuk ke admin (konvensi bus.sql: topic 'a.b' → bus_in.a_b(jsonb)). Pengirim sudah diverifikasi HMAC di bridge;
-- payload = data dari project pemilik, bukan sesi user. Gagal → seluruh batch diulang pengirim (idempoten lewat bus.inbox).

-- Pusat audit (ops.audit_logs append-only): salinan baris audit project lain, waktu asli dipertahankan.
create function bus_in.audit_log(p jsonb) returns void
language sql set search_path = '' as $$
  insert into ops.audit_logs (actor_id, action, target, before, after, at)
  select r.actor_id, r.action, r.target, r.before, r.after, coalesce(r.at, now()) from jsonb_populate_record(null::ops.audit_logs, p) r;
$$;

-- E-19 keputusan review yang diambil di project lain: hanya verifikasi org dari brand. Keputusan submisi milik admin (banding sekali,
-- tenggang lock) — selain org dilewati + alert, tidak menahan antrean.
create function bus_in.review_decision(p jsonb) returns void
language plpgsql set search_path = '' as $$
begin
  if p ->> 'target_type' is distinct from 'org' then
    perform ops.raise_alert('bus.rejected_payload', 'critical', jsonb_build_object('topic', 'review.decision', 'source', p ->> '_source',
                                                                                  'target_type', p ->> 'target_type'));
    return;
  end if;
  insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
  select r.target_type, r.target_id, r.actor_id, r.decision, r.reason_code, r.message, r.note
    from jsonb_populate_record(null::trust.review_decisions, p) r;
end $$;

-- Event yang dilewati creator/brand karena tidak sesuai kontrak (bus.reject) → alert di admin (email ops).
create function bus_in.bus_rejected(p jsonb) returns void
language sql set search_path = '' as $$
  select ops.raise_alert('bus.rejected_payload', 'critical', p - '_source' || jsonb_build_object('receiver', p ->> '_source'));
$$;

-- Inbox & pengiriman email/push satu pintu di admin. Undangan campaign dilengkapi rate per 1.000 views (rule milik admin).
create function bus_in.notify_user(p jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  body jsonb := coalesce(p -> 'payload', '{}');
begin
  -- event per pengirim (email/push memakai template platform): brand = org.*, agency.*, campaign.invited; creator = social.*
  if not (p ->> '_source' = 'brand' and (p ->> 'event' ~ '^(org|agency)\.' or p ->> 'event' = 'campaign.invited')
          or p ->> '_source' = 'creator' and p ->> 'event' ~ '^social\.') then
    perform ops.raise_alert('bus.rejected_payload', 'critical', jsonb_build_object('topic', 'notify.user', 'source', p ->> '_source',
                                                                                  'event', p ->> 'event'));
    return;
  end if;
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

-- Pemantauan bus (lihat bus.ping): ping terakhir tiap project pengirim + antrean macet yang dilaporkannya.
create table ops.bus_peers (
  source text primary key check (source in ('creator', 'brand')),
  pinged_at timestamptz not null default now(),  -- watermark (at dari ping): dasar lock/settle, bisa tertahan transaksi panjang
  seen_at timestamptz not null default now(),    -- ping terakhir diterima: tanda hidup antrean pengirim → admin
  stuck jsonb not null default '[]' check (jsonb_typeof(stuck) = 'array')
);
alter table ops.bus_peers enable row level security;
create policy bus_peers_iss on ops.bus_peers as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy bus_peers_admin_read on ops.bus_peers for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on ops.bus_peers to authenticated;

create function bus_in.bus_ping(p jsonb) returns void
language sql set search_path = '' as $$
  insert into ops.bus_peers (source, pinged_at, seen_at, stuck)
  select p ->> '_source', coalesce((p ->> 'at')::timestamptz, now()), now(),
         case when jsonb_typeof(p -> 'stuck') = 'array' then p -> 'stuck' else '[]' end
   where p ->> '_source' in ('creator', 'brand')
  on conflict (source) do update set pinged_at = greatest(ops.bus_peers.pinged_at, excluded.pinged_at), seen_at = now(),
                                     stuck = excluded.stuck;
$$;

-- job:bus-watch (5 menit): ping creator/brand tidak diterima > 15 menit (seen_at), antrean mereka yang macet, atau antrean admin
-- sendiri yang macet → alert kritis bus.stuck (email admin lewat job alert-notify; maks satu per jam). Watermark yang tertahan
-- > 1 jam oleh transaksi terbuka di pengirim (backup pg_dump, job malam, sesi lupa commit — entri stuck 'transaksi') bukan
-- antrean macet: alert terpisah bus.watermark_held (warning; lock/settle menunggu, tidak ada data hilang).
create function ops.watch_bus() returns void
language plpgsql security definer set search_path = '' as $$
declare
  late jsonb;
  peer_stuck jsonb;
  own_stuck jsonb;
  held jsonb;
begin
  select jsonb_agg(p.source order by p.source) into late from ops.bus_peers p where p.seen_at < now() - interval '15 minutes';
  select jsonb_agg(jsonb_build_object('source', p.source) || e.value) into peer_stuck
    from ops.bus_peers p cross join lateral jsonb_array_elements(p.stuck) e where e.value ->> 'target' <> 'transaksi';
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('source', p.source, 'watermark', p.pinged_at,
           'transaksi', (select jsonb_agg(e.value) from jsonb_array_elements(p.stuck) e where e.value ->> 'target' = 'transaksi')))
           order by p.source) into held
    from ops.bus_peers p where p.pinged_at < now() - interval '1 hour' and p.seen_at >= now() - interval '15 minutes';
  if held is not null then
    perform ops.raise_alert('bus.watermark_held', 'warning', jsonb_build_object('held', held), interval '1 hour');
  end if;
  select jsonb_agg(jsonb_build_object('target', s.target, 'since', s.created_at, 'attempts', s.attempts)) into own_stuck from bus.stuck() s;
  if late is not null or peer_stuck is not null or own_stuck is not null then
    perform ops.raise_alert('bus.stuck', 'critical', jsonb_strip_nulls(jsonb_build_object('late', late, 'peer_stuck', peer_stuck,
                                                                                         'admin_stuck', own_stuck)), interval '1 hour');
  end if;
end $$;
revoke execute on function bus_in.bus_ping(jsonb), bus_in.bus_rejected(jsonb), ops.watch_bus() from public;
select cron.schedule('bus-watch', '*/5 * * * *', $$select ops.watch_bus()$$);

