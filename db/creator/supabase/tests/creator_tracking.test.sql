-- test:creator.tracking — pipeline tracking milik creator (F-C02, F-C06, §11): akun sosmed + token Vault, submit (validasi atas
-- replika claim & campaign), snapshot, antrean poll (lease, backoff, akun tidak verified berhenti), event ke admin (rep.row,
-- notify.user, submission.post_gone) dan dari admin (social.reset, profile.anonymize). Jalankan: supabase test db --workdir db/creator
begin;
do $$ begin execute (select 'truncate ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' cascade'
  from pg_tables where schemaname in ('market', 'tracking', 'ops', 'bus')); end $$;
select no_plan();

create function pg_temp.events(p_target text, p_topic text) returns setof jsonb language sql as $$
  select payload from bus.outbox where target = p_target and topic = p_topic order by seq;
$$;
-- Submit seperti creator/social: argumen tetap, kecuali yang diganti.
create function pg_temp.submit(p_user text, p_claim text, p_account text, p_post text default 'x', p_posted timestamptz default now() - interval '1 hour',
                               p_caption text default '#mplid', p_duration int default 30, p_cover bigint default null) returns jsonb
language sql as $$
  select api.worker_create_submission(p_user::uuid, p_claim::uuid, p_account::uuid, p_post, 'https://tiktok.com/v/' || p_post, p_posted,
                                      p_caption, p_duration, p_cover);
$$;

insert into ops.settings (key, value) values ('auth.identity_issuer', '"https://auth.contoh.id/auth/v1"');
insert into market.profiles (id, username, display_name, status) values
  ('11111111-0000-0000-0000-00000000000a', 'andi', 'Andi', 'active'),
  ('11111111-0000-0000-0000-00000000000d', 'dedi', 'Dedi', 'active'),
  ('11111111-0000-0000-0000-00000000000e', 'eko', 'Eko', 'banned'),
  ('11111111-0000-0000-0000-00000000000f', 'fani', 'Fani', 'active');
insert into market.organizations (id, name, status, created_at) values ('44444444-0000-0000-0000-000000000001', 'Studio Satu', 'verified', now());
insert into market.campaigns (id, org_id, title, type, platforms, required_hashtags, required_mentions, required_links, min_duration_sec,
                              max_duration_sec, review_mode, min_followers, min_account_age_days, max_clips_per_clipper, allow_video_reuse,
                              status, submit_deadline, view_window_days) values
  ('55555555-0000-0000-0000-0000000000b0', '44444444-0000-0000-0000-000000000001', 'Submit', 'clipping', '{tiktok}', '{mplid}', '{}', '{}',
   15, 60, 'auto', 0, 0, 10, false, 'live', now() + interval '10 days', 30),
  ('55555555-0000-0000-0000-0000000000b1', '44444444-0000-0000-0000-000000000001', 'Review brand', 'clipping', '{tiktok}', '{}', '{}', '{}',
   null, null, 'brand', 0, 0, 10, false, 'live', now() + interval '10 days', 30),
  ('55555555-0000-0000-0000-0000000000a3', '44444444-0000-0000-0000-000000000001', 'Habis', 'clipping', '{tiktok}', '{}', '{}', '{}',
   null, null, 'auto', 0, 0, 10, false, 'exhausted', now() + interval '10 days', 30),
  ('55555555-0000-0000-0000-0000000000b9', '44444444-0000-0000-0000-000000000001', 'Lagu baru', 'music', '{tiktok}', '{}', '{}', '{}',
   null, null, 'auto', 0, 0, 10, false, 'live', now() + interval '10 days', 30);
insert into market.claims (id, campaign_id, user_id, status, expires_at, created_at) values
  ('88888888-0000-0000-0000-0000000000b0', '55555555-0000-0000-0000-0000000000b0', '11111111-0000-0000-0000-00000000000a', 'open', now() + interval '46 hours', now() - interval '2 hours'),
  ('88888888-0000-0000-0000-0000000000b1', '55555555-0000-0000-0000-0000000000b0', '11111111-0000-0000-0000-00000000000d', 'open', now() + interval '46 hours', now() - interval '2 hours'),
  ('88888888-0000-0000-0000-0000000000a3', '55555555-0000-0000-0000-0000000000a3', '11111111-0000-0000-0000-00000000000a', 'open', now() + interval '46 hours', now() - interval '2 hours'),
  ('88888888-0000-0000-0000-0000000000b2', '55555555-0000-0000-0000-0000000000b1', '11111111-0000-0000-0000-00000000000f', 'open', now() + interval '46 hours', now() - interval '2 hours'),
  ('88888888-0000-0000-0000-0000000000b9', '55555555-0000-0000-0000-0000000000b9', '11111111-0000-0000-0000-00000000000a', 'open', now() + interval '46 hours', now() - interval '2 hours'),
  ('88888888-0000-0000-0000-0000000000e0', '55555555-0000-0000-0000-0000000000b0', '11111111-0000-0000-0000-00000000000e', 'open', now() + interval '46 hours', now() - interval '2 hours');
insert into tracking.social_accounts (id, user_id, platform, external_id, handle, followers, platform_created_at) values
  ('99999999-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-00000000000a', 'tiktok', 'tt-andi', '@andi', 5000, now() - interval '400 days'),
  ('99999999-0000-0000-0000-0000000000a2', '11111111-0000-0000-0000-00000000000a', 'instagram', 'ig-andi', '@andi.ig', 5000, now() - interval '400 days'),
  ('99999999-0000-0000-0000-00000000000d', '11111111-0000-0000-0000-00000000000d', 'tiktok', 'tt-dedi', '@dedi', 5000, now() - interval '400 days'),
  ('99999999-0000-0000-0000-00000000000f', '11111111-0000-0000-0000-00000000000f', 'tiktok', 'tt-fani', '@fani', 5000, now() - interval '400 days');
select api.store_social_token('99999999-0000-0000-0000-00000000000a', '{"access_token":"tok-a"}');
select api.store_social_token('99999999-0000-0000-0000-00000000000d', jsonb_build_object('access_token', 'tok-d', 'expires_at', now() + interval '30 days')::text);
update tracking.social_accounts set status = 'verified' where id = '99999999-0000-0000-0000-00000000000e';
select ok(exists (select 1 from bus.outbox where target = 'admin' and topic = 'rep.row' and payload ->> 'table' = 'tracking.social_accounts'
                   and not payload -> 'row' ? 'token_ref'), 'akun sosmed direplika ke admin tanpa token_ref');
delete from bus.outbox;

-- ---------- akun sosmed ----------
select throws_ok($$ insert into tracking.social_accounts (user_id, platform, external_id, handle)
                    select '11111111-0000-0000-0000-00000000000a', 'tiktok', 'tt-' || g, '@andi' || g from generate_series(2, 4) g $$, '23514', null,
                 'akun TikTok ke-4 untuk clipper yang sama ditolak');
select throws_ok($$ insert into tracking.social_accounts (user_id, platform, external_id, handle)
                    values ('11111111-0000-0000-0000-00000000000d', 'tiktok', 'tt-andi', '@curian') $$, '23505', null,
                 'akun sosmed yang sudah terhubung tidak bisa dipasang clipper lain');
select is(api.worker_account_token('99999999-0000-0000-0000-00000000000a') - 'token',
          '{"id":"99999999-0000-0000-0000-00000000000a","user_id":"11111111-0000-0000-0000-00000000000a","platform":"tiktok",
            "external_id":"tt-andi","handle":"@andi","status":"verified"}'::jsonb, 'worker_account_token: akun + token');
select is(api.worker_account_token('99999999-0000-0000-0000-00000000000a') ->> 'token', '{"access_token":"tok-a"}', 'token dari Vault creator');
select is(api.worker_upsert_social_account('11111111-0000-0000-0000-00000000000f', 'instagram', 'ig-fani', '@fani.ig', 120,
            now() - interval '3 years', jsonb_build_object('access_token', 'tok-1', 'expires_at', now() + interval '1 hour')::text) is not null,
          true, 'connect akun baru + token');
select throws_ok($$ select api.worker_upsert_social_account('11111111-0000-0000-0000-00000000000f', 'tiktok', 'tt-andi', '@curian', 1, null, 'x') $$,
                 'P0001', 'social_taken', 'akun sosmed milik clipper lain ditolak');
select throws_ok($$ select api.worker_upsert_social_account('11111111-0000-0000-0000-00000000000e', 'tiktok', 'tt-eko', '@eko', 1, null, 'x') $$,
                 'P0001', 'profile_inactive', 'profil banned tidak bisa connect');
select is((select array_agg(a.handle) from api.worker_accounts_to_refresh(interval '6 hours') r join tracking.social_accounts a on a.id = r.account_id),
          array['@fani.ig'], 'refresh-tokens: hanya token yang kedaluwarsa dalam 6 jam');

-- ---------- submit (validasi atas replika claim & campaign) ----------
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000e', '88888888-0000-0000-0000-0000000000e0', '99999999-0000-0000-0000-00000000000a') $$,
                 'P0001', 'profile_inactive', 'submit: profil banned ditolak');
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', gen_random_uuid()::text, '99999999-0000-0000-0000-00000000000a') $$,
                 'P0001', 'claim_not_open', 'submit: claim tidak ada (belum tereplika)');
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b1', '99999999-0000-0000-0000-00000000000a') $$,
                 'P0001', 'not_your_claim', 'submit: claim milik orang lain');
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000a3', '99999999-0000-0000-0000-00000000000a') $$,
                 'P0001', 'campaign_closed', 'submit: campaign sudah exhausted (status replika admin)');
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0', '99999999-0000-0000-0000-00000000000d') $$,
                 'P0001', 'account_not_yours', 'submit: akun sosmed orang lain');
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0', '99999999-0000-0000-0000-0000000000a2') $$,
                 'P0001', 'platform_not_allowed', 'submit: platform di luar campaign');
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0', '99999999-0000-0000-0000-00000000000a',
                    'x', now() - interval '3 hours') $$, 'P0001', 'posted_before_claim', 'submit: diposting sebelum claim');
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0', '99999999-0000-0000-0000-00000000000a',
                    'x', now() - interval '1 hour', 'seru banget') $$, 'P0001', 'missing_tags:#mplid', 'submit: hashtag wajib hilang (kode + daftar)');
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0', '99999999-0000-0000-0000-00000000000a',
                    'x', now() - interval '1 hour', '#mplid', 5) $$, 'P0001', 'duration_out_of_range', 'submit: durasi di luar batas');
-- Regresi R75: suspend yang sudah lewat masanya tidak memblok submit.
update market.profiles set status = 'suspended', suspended_until = now() - interval '1 hour' where id = '11111111-0000-0000-0000-00000000000a';
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0', '99999999-0000-0000-0000-00000000000a',
                    'x', now() - interval '1 hour', '#mplid', 5) $$, 'P0001', 'duration_out_of_range', 'R75: suspend kedaluwarsa lolos cek profil submit');
update market.profiles set status = 'active', suspended_until = null where id = '11111111-0000-0000-0000-00000000000a';
-- Regresi R67: bergabung ke org pemilik campaign (replika brand) setelah claim → submit ditolak own_org.
insert into market.org_members (org_id, user_id, role, created_at) values ('44444444-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'brand_manager', now());
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0', '99999999-0000-0000-0000-00000000000a') $$,
                 'P0001', 'not_eligible:own_org', 'R67: anggota org pemilik (bergabung setelah claim) tidak bisa submit');
delete from market.org_members;
-- Regresi R63: syarat follower/umur akun berlaku untuk akun yang dipakai submit.
update market.campaigns set min_followers = 1000000000 where id = '55555555-0000-0000-0000-0000000000b0';
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0', '99999999-0000-0000-0000-00000000000a') $$,
                 'P0001', 'not_eligible:min_followers', 'R63: akun submit di bawah min_followers ditolak');
update market.campaigns set min_followers = 0, min_account_age_days = 30000 where id = '55555555-0000-0000-0000-0000000000b0';
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0', '99999999-0000-0000-0000-00000000000a') $$,
                 'P0001', 'not_eligible:min_account_age', 'R63: akun submit di bawah min_account_age ditolak');
update market.campaigns set min_account_age_days = 0 where id = '55555555-0000-0000-0000-0000000000b0';
create temp table t_s10 as select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0',
  '99999999-0000-0000-0000-00000000000a', 'vid-10', now() - interval '1 hour', 'Mantap #MPLID', 30, 1234567890123) as r;
select is((select r ->> 'status' from t_s10), 'tracking', 'review auto → status tracking (keputusan admin dari review_route)');
select is((select review_route || ':' || status::text from tracking.submissions where post_id = 'vid-10'), 'auto:validating',
          'creator menyimpan review_route; status = milik admin (menunggu replika)');
select is((select payload -> 'row' ->> 'review_route' from bus.outbox where target = 'admin' and topic = 'rep.row'
             and payload ->> 'table' = 'tracking.submissions'), 'auto', 'submisi baru direplika ke admin (isi + review_route)');
select ok(not exists (select 1 from bus.outbox where payload ->> 'table' = 'tracking.submissions' and payload -> 'row' ? 'status'),
          'status/counted_views tidak dikirim balik ke admin');
-- Regresi R64: claim kedua tidak melewati max_clips_per_clipper saat submit.
update market.campaigns set max_clips_per_clipper = 1 where id = '55555555-0000-0000-0000-0000000000b0';
insert into market.claims (id, campaign_id, user_id, status, expires_at, created_at) values
  ('88888888-0000-0000-0000-000000000064', '55555555-0000-0000-0000-0000000000b0', '11111111-0000-0000-0000-00000000000a', 'open', now() + interval '46 hours', now() - interval '2 hours');
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-000000000064', '99999999-0000-0000-0000-00000000000a', 'vid-r64') $$,
                 'P0001', 'not_eligible:max_clips', 'R64: submit claim kedua saat kuota clip penuh ditolak');
update market.campaigns set max_clips_per_clipper = 10 where id = '55555555-0000-0000-0000-0000000000b0';
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000d', '88888888-0000-0000-0000-0000000000b1', '99999999-0000-0000-0000-00000000000d', 'vid-10') $$,
                 'P0001', 'already_submitted', 'submit: video sama di campaign sama');
select is(pg_temp.submit('11111111-0000-0000-0000-00000000000d', '88888888-0000-0000-0000-0000000000b1', '99999999-0000-0000-0000-00000000000d',
                         'vid-11', now() - interval '1 hour', '#mplid', null) ->> 'status',
          'in_review', 'durasi tidak diketahui + campaign berbatas durasi → in_review walau review auto');
select throws_ok($$ select pg_temp.submit('11111111-0000-0000-0000-00000000000f', '88888888-0000-0000-0000-0000000000b2', '99999999-0000-0000-0000-00000000000f', 'vid-10', now() - interval '1 hour', 'halo') $$,
                 'P0001', 'reused_video', 'submit: video yang dipakai di campaign lain (allow_video_reuse mati)');
select is(pg_temp.submit('11111111-0000-0000-0000-00000000000f', '88888888-0000-0000-0000-0000000000b2', '99999999-0000-0000-0000-00000000000f',
                         'vid-12', now() - interval '1 hour', 'halo', null) ->> 'status', 'in_review', 'review brand → in_review');
select is(pg_temp.submit('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b9', '99999999-0000-0000-0000-00000000000a',
                         'vid-music', now() - interval '1 hour', 'pakai sound') ->> 'status',
          'in_review', 'regresi AA-11: campaign musik TikTok → in_review walau review auto');

-- ---------- snapshot & antrean poll ----------
create temp table t_ids as select id from tracking.submissions where post_id = 'vid-10';
-- status tracking + jadwal = replika admin
select api.bus_receive('admin', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.row', 'payload',
  jsonb_build_object('table', 'tracking.submissions', 'op', 'upsert', 'key', jsonb_build_object('id', (select id from t_ids)),
    'row', jsonb_build_object('id', (select id from t_ids), 'status', 'tracking', 'counted_views', 0, 'next_poll_at', now() - interval '1 minute')))));
select is((select status::text from tracking.submissions where id = (select id from t_ids)), 'tracking', 'status & jadwal dari replika admin');
select is(api.worker_submission_context((select id from t_ids)) #>> '{campaign,required_hashtags,0}', 'mplid', 'context memuat brief untuk cek caption');
select is((api.worker_submission_context((select id from t_ids)) ->> 'token'), '{"access_token":"tok-a"}', 'context memuat token akun');
select is(tracking.enqueue_due_submissions(), 1, 'job track-due mengantre submisi jatuh tempo');
select is(tracking.enqueue_due_submissions(), 0, 'lease 1 jam: tidak diantre dua kali');
select is((select count(*)::int from pgmq.q_tracking), 1, 'satu pesan di queue tracking');
create temp table t_rec as select api.worker_record_snapshot((select id from t_ids), 2000, 100, 5, 1, '#mplid mantap', '{"api":"tiktok"}', '{"reach":1500}') as r;
select is((select raw from tracking.view_snapshots where id = (select (r ->> 'snapshot_id')::bigint from t_rec)),
          '{"api":"tiktok","extra":{"reach":1500},"caption":"#mplid mantap"}'::jsonb, 'raw memuat extra & caption untuk fraud di admin');
select is((select last_views::text || ':' || (last_snapshot_at is not null)::text from tracking.submissions where id = (select id from t_ids)),
          '2000:true', 'snapshot terakhir tercatat');
select ok(exists (select 1 from bus.outbox where target = 'admin' and topic = 'rep.row' and payload ->> 'table' = 'tracking.view_snapshots'
                   and (payload -> 'row' ->> 'views')::bigint = 2000), 'snapshot direplika ke admin (fraud, accrual, jadwal poll)');
select throws_ok($$ update tracking.view_snapshots set views = 1 $$, '42501', null, 'snapshot append-only');
select api.worker_defer((select id from t_ids), now() + interval '6 days');
select is((select lease_until from tracking.submissions where id = (select id from t_ids)), now() + interval '6 days',
          'worker_defer: tidak diantre sampai waktu yang diminta');
select api.worker_defer((select id from t_ids), now() + interval '90 days');
select is((select lease_until from tracking.submissions where id = (select id from t_ids)), (select posted_at + interval '30 days' from tracking.submissions where id = (select id from t_ids)),
          'worker_defer: tidak melewati akhir view window (poll final)');
-- Regresi R17: retry tertunda (Retry-After/backoff) → penjadwal tidak mengantre ulang walau jadwal & lease lewat.
update tracking.submissions set lease_until = null where id = (select id from t_ids);
select api.worker_retry_later('tracking', (select max(msg_id) from pgmq.q_tracking), 3600, (select id from t_ids));
select is(tracking.enqueue_due_submissions(), 0, 'regresi R17: penjadwal menunggu retry_after');
update tracking.submissions set retry_after = null where id = (select id from t_ids);
-- token kedaluwarsa → tracking berhenti (akun tidak verified), notifikasi sekali lewat admin; reconnect → lanjut.
select api.worker_account_status('99999999-0000-0000-0000-00000000000a', 'expired');
select api.worker_account_status('99999999-0000-0000-0000-00000000000a', 'expired');
select is((select array_agg(e ->> 'payload') from pg_temp.events('admin', 'notify.user') e where e ->> 'event' = 'social.token_expired'),
          array['{"handle": "@andi", "platform": "tiktok", "account_id": "99999999-0000-0000-0000-00000000000a", "paused_count": 1}'],
          'token kedaluwarsa: notifikasi sekali (lewat admin) + jumlah video yang berhenti');
select is(tracking.enqueue_due_submissions(), 0, 'token kedaluwarsa: tracking berhenti');
select api.worker_account_status('99999999-0000-0000-0000-00000000000a', 'verified');
select is(tracking.enqueue_due_submissions(), 1, 'reconnect: tracking lanjut (jadwal admin tidak hilang)');
-- submisi yang tidak dilacak: snapshot no-op
update tracking.submissions set status = 'settled' where post_id = 'vid-11';
select is(api.worker_record_snapshot((select id from tracking.submissions where post_id = 'vid-11'), 9999, null, null, null, null, null) ->> 'snapshot_id',
          null, 'submisi yang tidak dilacak tidak dicatat (no-op)');
select api.worker_post_gone((select id from t_ids), 'deleted');
select is((select payload from bus.outbox where target = 'admin' and topic = 'submission.post_gone'),
          jsonb_build_object('submission_id', (select id from t_ids), 'reason', 'deleted'), 'post hilang → event ke admin (earning hangus di sana)');
select is(tracking.enqueue_due_submissions(), 0, 'post hilang: tidak dipoll lagi sambil menunggu status admin');
select throws_ok($$ select * from api.worker_dequeue('email', 5) $$, 'P0001', 'invalid:queue', 'creator hanya punya queue tracking');

-- ---------- event dari admin ----------
-- Regresi R36-1: batas akun per platform diturunkan → perubahan status akun yang sudah ada tetap jalan.
insert into ops.settings (key, value) values ('public.market.max_accounts_per_platform', '0');
select lives_ok($$ select bus_in.social_reset('{"account_id":"99999999-0000-0000-0000-00000000000d"}') $$,
                'regresi AA-10/R36-1: social.reset jalan walau batas akun diturunkan');
delete from ops.settings where key = 'public.market.max_accounts_per_platform';
select is((select status || ':' || (token_ref is null)::text from tracking.social_accounts where id = '99999999-0000-0000-0000-00000000000d'),
          'revoked:true', 'social.reset: status revoked, token dilepas');
select ok(not exists (select 1 from vault.secrets where name = 'social:99999999-0000-0000-0000-00000000000d'), 'social.reset: token Vault dihapus');
select ok(exists (select 1 from pg_temp.events('admin', 'notify.user') e where e ->> 'event' = 'social.token_expired'
                   and e ->> 'user_id' = '11111111-0000-0000-0000-00000000000d'), 'social.reset: clipper dikabari');
-- Regresi R34-1: refresh token yang sedang jalan saat reset tidak menghidupkan akun lagi.
select api.worker_account_status('99999999-0000-0000-0000-00000000000d', 'expired');
select api.store_social_token('99999999-0000-0000-0000-00000000000d', '{"access_token":"refresh-telat"}');
select api.worker_account_status('99999999-0000-0000-0000-00000000000d', 'verified');
select is((select status || ':' || (token_ref is null)::text from tracking.social_accounts where id = '99999999-0000-0000-0000-00000000000d'),
          'revoked:true', 'regresi R34-1: refresh yang selesai setelah reset tidak menulis token / memverifikasi ulang');
select api.worker_upsert_social_account('11111111-0000-0000-0000-00000000000d', 'tiktok', 'tt-dedi', '@dedi', null, null, '{"access_token":"baru"}');
select is((select status || ':' || (token_ref is not null)::text from tracking.social_accounts where id = '99999999-0000-0000-0000-00000000000d'),
          'verified:true', 'akun yang direset bisa disambung ulang oleh pemiliknya (token baru tersimpan)');
-- hapus akun (alur 12): token dihapus, akun tanpa submisi dihapus, sisanya diputus permanen
select bus_in.profile_anonymize('{"user_id":"11111111-0000-0000-0000-00000000000f"}');
select is((select array_agg(platform::text || ':' || status order by platform) from tracking.social_accounts where user_id = '11111111-0000-0000-0000-00000000000f'),
          array['tiktok:disconnected'], 'hapus akun: akun bersubmisi diputus, akun tanpa submisi dihapus');
select ok(not exists (select 1 from vault.secrets v where v.name like 'social:%'
                       and not exists (select 1 from tracking.social_accounts a where a.token_ref = v.id)), 'hapus akun: token Vault ikut dihapus');
-- config dari admin (replika)
select lives_ok($$ select api.bus_receive('admin', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.row', 'payload',
  jsonb_build_object('table', 'ops.settings', 'op', 'upsert', 'key', '{"key":"tracking.poll_schedule"}',
    'row', jsonb_build_object('key', 'tracking.poll_schedule', 'value', '[{"until_hours":null,"every_hours":12}]'::jsonb, 'updated_at', now()))))) $$,
  'config admin tiba sebagai replika');
select is(ops.cfg('tracking.poll_schedule'), '[{"until_hours":null,"every_hours":12}]'::jsonb, 'config replika terbaca');

-- ---------- hak akses ----------
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p where p.pronamespace = 'api'::regnamespace
            and has_function_privilege('anon', p.oid, 'execute')), array['health'], 'anon hanya bisa health (monitor uptime)');
select is((select array_agg(k order by k) from jsonb_object_keys(api.health()) k), array['at', 'db', 'last_received', 'outbox'],
          'health: angka & waktu saja (tanpa pesan error / URL)');
select is(api.health() -> 'outbox' -> 'admin' ->> 'pending', (select count(*)::text from bus.outbox where target = 'admin' and sent_at is null),
          'health: antrean keluar per target');
create temp table t_ping as select bus.ping() as id;
select ok(pg_has_role((select p.proowner from pg_proc p where p.oid = 'bus.ping()'::regprocedure), 'pg_read_all_stats', 'member'),
          'CL13: pemilik bus.ping bisa membaca transaksi semua sesi (watermark; tanpa ini fail-closed: at = -infinity)');
select ok((select (payload ->> 'at')::timestamptz <= clock_timestamp() and (payload ->> 'at')::timestamptz > '-infinity' from bus.outbox where id = (select id from t_ping)),
          'bus.ping: at terbaca (sesi lain terlihat)');
select ok((select payload ->> 'source' = 'creator' and payload -> 'stuck' = '[]' and target = 'admin' from bus.outbox where id = (select id from t_ping)),
          'bus.ping ke admin: sumber + antrean macet');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'api'::regnamespace and p.proname ~ '^worker_'
            and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0,
          'authenticated/anon tidak bisa EXECUTE RPC worker');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'api'::regnamespace and p.proname ~ '^worker_'
            and not has_function_privilege('service_role', p.oid, 'execute')), 0, 'service_role bisa EXECUTE semua RPC worker');
set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1","iss":"https://auth.contoh.id/auth/v1"}';
select throws_ok($$ select token_ref from tracking.social_accounts $$, '42501', null, 'token_ref tidak bisa dibaca browser');
select is((select count(*)::int from api.claims), 4, 'clipper melihat claim miliknya saja (replika admin)');
reset role;

select * from finish();
rollback;
