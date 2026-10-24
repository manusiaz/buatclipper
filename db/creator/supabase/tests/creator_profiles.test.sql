-- test:creator.profiles — profil E-01 & storage avatar milik project creator (alur 1, 5, 12, F-C01, F-C16). Efek ke project lain
-- diperiksa sebagai event outbox: rep.row ke admin & brand, referral.record ke admin. Jalankan: supabase test db --workdir db/creator
begin;
do $$ begin execute (select 'truncate ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' cascade'
  from pg_tables where schemaname in ('market', 'ops', 'bus')); end $$;
select no_plan();

create function pg_temp.jwt(p_sub text) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'aal', 'aal1',
    'iss', 'https://auth.contoh.id/auth/v1')::text, true);
$$;
grant execute on function pg_temp.jwt(text) to anon, authenticated;
create function pg_temp.events(p_target text, p_topic text) returns setof jsonb language sql as $$
  select payload from bus.outbox where target = p_target and topic = p_topic order by seq;
$$;

insert into ops.settings (key, value) values ('auth.identity_issuer', '"https://auth.contoh.id/auth/v1"');
insert into market.profiles (id, username, display_name, status) values
  ('11111111-0000-0000-0000-0000000000b0', 'budi', 'Budi', 'active'),
  ('11111111-0000-0000-0000-0000000000d0', 'dedi', 'Dedi', 'banned');
delete from bus.outbox;

-- ---------- api.ensure_profile ----------
set local role anon;
select throws_ok($$ select api.ensure_profile('anon', 'Anon') $$, '42501', null, 'anon tidak bisa memanggil ensure_profile');
reset role;

set local role authenticated;
set local request.jwt.claims = '{"sub":"11111111-0000-0000-0000-00000000000a","role":"authenticated","aal":"aal1","iss":"https://evil.example/auth/v1"}';
select throws_ok($$ select api.ensure_profile('andi', 'Andi') $$, '42501', 'auth:no_session', 'JWT terbitan lain ditolak');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select is((select created from api.ensure_profile(' Andi ', ' Andi A ', 'KODEREF1')), true, 'profil baru (username dinormalkan)');
select throws_ok($$ select api.ensure_profile('budi', 'Andi') $$, '23505', 'username_taken', 'username milik orang lain ditolak');
select throws_ok($$ select api.ensure_profile('Deleted_abc', 'Andi') $$, '23505', 'username_taken',
                 'C4: prefix deleted_ direservasi (nama profil yang dihapus)');
select is((select created from api.ensure_profile('andi_baru', 'Andi B', 'kodelain')), false, 'profil yang ada diperbarui');
select throws_ok($$ select api.ensure_profile('andi_baru', 'Andi B', null, '11111111-0000-0000-0000-0000000000b0/a.webp') $$,
                 '22023', 'invalid:avatar_path', 'avatar di folder user lain ditolak');
select throws_ok($$ select api.ensure_profile('andi_baru', 'Andi B', null, '11111111-0000-0000-0000-00000000000a/../x.webp') $$,
                 '22023', 'invalid:avatar_path', 'path avatar dengan .. ditolak');
select lives_ok($$ select api.ensure_profile('andi_baru', 'Andi B', null, '11111111-0000-0000-0000-00000000000a/a.webp') $$,
                'avatar milik sendiri diterima');
select lives_ok($$ select api.ensure_profile('andi_baru', 'Andi C') $$, 'update tanpa p_avatar_path');
select is((select avatar_path || ' ' || display_name from api.my_profile), '11111111-0000-0000-0000-00000000000a/a.webp Andi C',
          'avatar dipertahankan saat update tanpa avatar');
select throws_ok($$ update market.profiles set trust_score = 100 where id = '11111111-0000-0000-0000-00000000000a' $$, '42501', null,
                 'browser tidak bisa menulis profil langsung');
select pg_temp.jwt('11111111-0000-0000-0000-0000000000d0');
select throws_ok($$ select api.ensure_profile('dedi', 'Dedi 2') $$, '42501', 'not_eligible:profile_inactive', 'profil banned tidak bisa diubah');
reset role;
select is((select array_agg(e ->> 'code') from pg_temp.events('admin', 'referral.record') e), array['koderef1'],
          'referral.record ke admin hanya untuk profil baru (kode dinormalkan)');
select is((select payload -> 'row' ->> 'display_name' from bus.outbox where target = 'admin' and topic = 'rep.row'
             and payload ->> 'table' = 'market.profiles' order by seq desc limit 1), 'Andi C', 'isi profil direplika ke admin');
select ok(not exists (select 1 from bus.outbox where topic = 'rep.row' and payload ->> 'table' = 'market.profiles'
                       and (payload -> 'row' ? 'trust_score' or payload -> 'row' ? 'status')), 'kolom milik admin tidak dikirim balik');
select ok(exists (select 1 from bus.outbox where target = 'brand' and topic = 'rep.row' and payload ->> 'table' = 'market.profiles'
                   and not payload -> 'row' ? 'created_at'), 'brand menerima username/nama/avatar saja');

-- ---------- event masuk ----------
select bus_in.profile_ensure('{"user_id":"11111111-0000-0000-0000-0000000000f1","username":"budi","display_name":"PIC"}');
select ok((select username ~ '^m_[0-9a-f]{12}$' and display_name = 'PIC' from market.profiles where id = '11111111-0000-0000-0000-0000000000f1'),
          'profile.ensure: username terpakai → m_<hex>');
select bus_in.profile_ensure('{"user_id":"11111111-0000-0000-0000-0000000000f3","username":"deleted_abc"}');
select ok((select username ~ '^m_[0-9a-f]{12}$' from market.profiles where id = '11111111-0000-0000-0000-0000000000f3'),
          'C4: profile.ensure dengan username deleted_ → m_<hex>');
select bus_in.profile_ensure('{"user_id":"11111111-0000-0000-0000-0000000000f2","username":"pic_toko"}');
select bus_in.profile_ensure('{"user_id":"11111111-0000-0000-0000-0000000000f2","username":"lain"}');
select is((select username || ' ' || display_name from market.profiles where id = '11111111-0000-0000-0000-0000000000f2'),
          'pic_toko Anggota brand', 'profile.ensure: username pilihan dipakai, event ulang tidak mengubah profil');
update bus.outbox set sent_at = now() where payload -> 'key' ->> 'id' = '11111111-0000-0000-0000-00000000000a';
select ok(exists (select 1 from bus.outbox where sent_at is not null and payload -> 'row' ->> 'username' = 'andi_baru'),
          'prasyarat: salinan username lama ada di outbox terkirim');
insert into bus.outbox (target, topic, payload, sent_at)
values ('admin', 'notify.user', '{"user_id":"11111111-0000-0000-0000-00000000000a","event":"social.connected","payload":{"handle":"@andi"}}', now());
select bus_in.profile_anonymize('{"user_id":"11111111-0000-0000-0000-00000000000a"}');
select ok(not exists (select 1 from bus.outbox where sent_at is not null and payload ->> 'user_id' = '11111111-0000-0000-0000-00000000000a'),
          'CL9: salinan notifikasi (handle) di outbox terkirim ikut dihapus');
select ok(not exists (select 1 from bus.outbox where sent_at is not null and payload -> 'key' ->> 'id' = '11111111-0000-0000-0000-00000000000a'),
          'CL4: hapus akun menghapus salinan profil lama di outbox (UU PDP), tidak menunggu retensi');
select ok((select username like 'deleted\_%' and display_name = 'Akun dihapus' and avatar_path is null from market.profiles
           where id = '11111111-0000-0000-0000-00000000000a'), 'profile.anonymize mengosongkan isi profil');
-- Review R89-2: hapus akun sebelum profil creator ada → nisan closed; JWT yang belum kedaluwarsa tidak bisa membuat profil lagi
select bus_in.profile_anonymize('{"user_id":"11111111-0000-0000-0000-0000000000e1"}');
select is((select status::text from market.profiles where id = '11111111-0000-0000-0000-0000000000e1'), 'closed',
          'R89-2: profile.anonymize tanpa profil → nisan closed');
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-0000000000e1');
select throws_ok($$ select api.ensure_profile('hidup_lagi', 'Hidup') $$, '42501', 'not_eligible:profile_inactive',
                 'R89-2: akun yang dihapus tidak bisa membuat profil lagi');
reset role;
select lives_ok($$ select api.bus_receive('admin', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.row',
  'payload', jsonb_build_object('table', 'market.profiles', 'op', 'UPDATE',
    'row', jsonb_build_object('id', '11111111-0000-0000-0000-0000000000b0', 'status', 'suspended', 'trust_score', 20))))) $$,
  'replika status/trust dari admin diterima');
select is((select status::text || ':' || trust_score from market.profiles where id = '11111111-0000-0000-0000-0000000000b0'), 'suspended:20',
          'status & trust score = replika admin');

-- ---------- storage avatar ----------
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-0000000000b0');
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', '11111111-0000-0000-0000-0000000000b0/a.webp') $$,
                'user unggah avatar ke foldernya');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', '11111111-0000-0000-0000-00000000000a/a.webp') $$,
                 '42501', null, 'user tidak bisa unggah avatar ke folder orang lain');
reset role;

select * from finish();
rollback;
