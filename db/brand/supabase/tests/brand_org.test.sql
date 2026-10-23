-- test:brand.org — org, tim, undangan, agency di project brand (F-B01, F-B12, F-A07, alur 5). Efek ke project lain diperiksa
-- sebagai event outbox: notify.user / audit.log / review.decision / org.owner_lost ke admin, profile.ensure ke creator, rep.row ke
-- admin & creator. Jalankan: supabase test db --workdir db/brand
begin;
do $$ begin execute (select 'truncate ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' cascade'
  from pg_tables where schemaname in ('market', 'ops', 'bus')); end $$;
select no_plan();

create function pg_temp.jwt(p_sub text, p_roles text[] default '{}', p_aal text default 'aal1', p_extra jsonb default '{}')
returns void language sql as $$
  select set_config('request.jwt.claims', (jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'aal', p_aal,
    'iss', 'https://auth.contoh.id/auth/v1', 'app_roles', to_jsonb(p_roles), 'kyc', 'none',
    'consent_ok', jsonb_build_object('clipper', true, 'brand', true)) || p_extra)::text, true);
$$;
grant execute on function pg_temp.jwt(text, text[], text, jsonb) to anon, authenticated;
create temp table t_ids (k text primary key, id uuid, tok text);
grant all on t_ids to anon, authenticated;
-- event outbox ke target, urut
create function pg_temp.events(p_target text, p_topic text) returns setof jsonb language sql as $$
  select payload from bus.outbox where target = p_target and topic = p_topic order by seq;
$$;

insert into ops.settings (key, value) values ('auth.identity_issuer', '"https://auth.contoh.id/auth/v1"');
insert into market.profiles (id, username, display_name, status) values
  ('22222222-0000-0000-0000-0000000000a1', 'owner1', 'Owner 1', 'active'),
  ('22222222-0000-0000-0000-0000000000b1', 'manager1', 'Manager 1', 'active'),
  ('22222222-0000-0000-0000-0000000000a2', 'owner2', 'Owner 2', 'active'),
  ('22222222-0000-0000-0000-0000000000e1', 'agency1', 'Agency 1', 'active'),
  ('22222222-0000-0000-0000-0000000000d1', 'banned1', 'Banned', 'banned');
insert into market.organizations (id, name, org_type, legal_name, npwp, address, status, verified_by, verified_at, created_by, is_agency) values
  ('44444444-0000-0000-0000-000000000001', 'Studio Satu', 'badan', 'PT Studio Satu', '0123456789012345', 'Jakarta', 'verified',
   '33333333-0000-0000-0000-0000000000ad', now(), '22222222-0000-0000-0000-0000000000a1', false),
  ('44444444-0000-0000-0000-000000000002', 'Toko Dua', 'perorangan', null, null, null, 'pending_verification', null, null,
   '22222222-0000-0000-0000-0000000000a2', false),
  ('44444444-0000-0000-0000-0000000000a9', 'Agensi Kreatif', 'badan', 'PT Agensi Kreatif', '0123456789012399', 'Bandung', 'verified',
   '33333333-0000-0000-0000-0000000000ad', now(), '22222222-0000-0000-0000-0000000000e1', true);
insert into market.org_members (org_id, user_id, role) values
  ('44444444-0000-0000-0000-000000000001', '22222222-0000-0000-0000-0000000000a1', 'brand_owner'),
  ('44444444-0000-0000-0000-000000000001', '22222222-0000-0000-0000-0000000000b1', 'brand_manager'),
  ('44444444-0000-0000-0000-000000000002', '22222222-0000-0000-0000-0000000000a2', 'brand_owner'),
  ('44444444-0000-0000-0000-0000000000a9', '22222222-0000-0000-0000-0000000000e1', 'brand_owner');

-- ---------- replikasi ----------
select is((select payload -> 'row' from bus.outbox where target = 'creator' and topic = 'rep.row'
             and payload ->> 'table' = 'market.organizations' and payload #>> '{key,id}' = '44444444-0000-0000-0000-000000000001'),
          jsonb_build_object('id', '44444444-0000-0000-0000-000000000001', 'name', 'Studio Satu', 'is_agency', false, 'status', 'verified',
                             'verified_at', (select to_jsonb(verified_at) from market.organizations where id = '44444444-0000-0000-0000-000000000001'),
                             'created_at', (select to_jsonb(created_at) from market.organizations where id = '44444444-0000-0000-0000-000000000001')),
          'replika org ke creator: hanya nama, agency, status (tanpa nama legal/NPWP/alamat)');
select ok((select payload -> 'row' ? 'npwp' from bus.outbox where target = 'admin' and topic = 'rep.row'
             and payload ->> 'table' = 'market.organizations' and payload #>> '{key,id}' = '44444444-0000-0000-0000-000000000001'),
          'replika org ke admin membawa data badan (faktur)');
select is((select count(*)::int from bus.outbox where topic = 'rep.row' and payload ->> 'table' = 'market.org_members'), 8,
          'anggota org direplika ke admin & creator (4 × 2)');

-- ---------- org & tim (F-B01, F-B12, F-A07) ----------
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2', p_extra => '{"consent_ok":{"clipper":true,"brand":false}}');
select throws_ok($$ select api.create_org('Brand Baru', 'perorangan') $$, 'P0001', 'consent_required:brand',
                 'create_org butuh consent_ok.brand');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000d1');
select throws_ok($$ select api.create_org('Brand Banned', 'perorangan') $$, 'P0001', 'not_eligible:profile_inactive',
                 'profil diblokir (replika) tidak bisa membuat org');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2');
select throws_ok($$ select api.create_org('PT Baru', 'badan', 'PT Baru Jaya', '123', 'Jakarta') $$, 'P0001', 'invalid:npwp',
                 'badan usaha wajib NPWP 15/16 digit');
select throws_ok($$ select api.create_org('Toko Tiga', 'perorangan', null, '3171012345670001') $$, 'P0001', 'invalid:perorangan_pii',
                 'org perorangan tidak menyimpan NIK/alamat');
select throws_ok($$ select api.create_org('PT Tanpa Alamat', 'badan', 'PT Tanpa Alamat', '012345678901234') $$, 'P0001', 'invalid:address',
                 'regresi AB-12: badan usaha wajib alamat (dipakai di faktur)');
insert into t_ids (k, id) select 'org_new', api.create_org('PT Baru', 'badan', 'PT Baru Jaya', '01.234.567.8-901.234', 'Jakarta');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000f0');
select lives_ok($$ select api.create_org('Brand Pendatang', 'perorangan') $$,
                'user yang profilnya belum tereplika (baru onboarding) tetap bisa membuat org');
reset role;
select is((select status::text || ':' || npwp from market.organizations where id = (select id from t_ids where k = 'org_new')),
          'pending_verification:012345678901234', 'org baru pending_verification, NPWP dinormalisasi angka');
select is((select role::text from market.org_members where org_id = (select id from t_ids where k = 'org_new')
             and user_id = '22222222-0000-0000-0000-0000000000a2'), 'brand_owner', 'pembuat org = brand_owner');
select ok(exists (select 1 from pg_temp.events('creator', 'profile.ensure') e where e ->> 'user_id' = '22222222-0000-0000-0000-0000000000f0'),
          'pembuat org memastikan profil ada di project profil (event profile.ensure)');

-- manage_org: admin_ops aal1 ditolak; aal2 verify → verified + keputusan review + notifikasi + audit (event ke admin)
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal1');
select throws_ok($$ select api.manage_org('44444444-0000-0000-0000-000000000002', 'verify') $$, '42501', 'auth:forbidden',
                 'manage_org menolak admin tanpa aal2');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select throws_ok($$ select api.manage_org('44444444-0000-0000-0000-000000000002', 'verify') $$, '42501', 'auth:forbidden',
                 'manage_org menolak brand_owner');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select throws_ok($$ select api.manage_org('44444444-0000-0000-0000-000000000002', 'reject') $$, 'P0001', 'invalid:reason',
                 'tolak org wajib alasan');
select throws_ok($$ select api.manage_org('44444444-0000-0000-0000-000000000002', 'set_fee', '{"mgmt_fee_pct": 10}') $$, 'P0001',
                 'invalid:action', 'fee org bukan milik brand (api.manage_org set_fee di admin)');
select lives_ok($$ select api.manage_org((select id from t_ids where k = 'org_new'), 'reject',
                                         '{"reason":"npwp_invalid","message":"NPWP tidak cocok"}') $$, 'admin_ops menolak org');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select throws_ok($$ select api.update_org((select id from t_ids where k = 'org_new'), 'PT Baru', 'PT Baru Jaya', '0123456789012345', 'Jakarta') $$,
                 '42501', 'auth:forbidden', 'hanya brand_owner org itu yang bisa mengubah data org');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2');
select lives_ok($$ select api.update_org((select id from t_ids where k = 'org_new'), 'PT Baru', 'PT Baru Jaya Abadi', '0123456789012345',
                                         'Jl. Sudirman 1, Jakarta') $$,
                'regresi AB-1: org ditolak diperbaiki brand_owner sendiri (tetap pending = diajukan ulang ke antrean admin)');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select lives_ok($$ select api.manage_org((select id from t_ids where k = 'org_new'), 'verify') $$, 'admin memverifikasi data perbaikan');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2');
select api.update_org((select id from t_ids where k = 'org_new'), 'PT Baru Jaya', 'PT Baru Jaya Abadi', '0123456789012345', 'Jl. Sudirman 1, Jakarta');
reset role;
select is((select status::text from market.organizations where id = (select id from t_ids where k = 'org_new')), 'verified',
          'ganti nama tampilan saja tidak perlu verifikasi ulang');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2');
select api.update_org((select id from t_ids where k = 'org_new'), 'PT Baru Jaya', 'PT Baru Jaya Abadi', '0123456789012345', 'Jl. Thamrin 2, Jakarta');
reset role;
select is((select status::text || ':' || (verified_at is null)::text from market.organizations where id = (select id from t_ids where k = 'org_new')),
          'pending_verification:true', 'regresi AB-1: ubah alamat/NPWP/nama legal org verified → verifikasi ulang');
select ok(exists (select 1 from ops.audit_logs where action = 'org.update' and target = 'org:' || (select id from t_ids where k = 'org_new')),
          'perubahan data org tercatat di audit');
select ok(exists (select 1 from pg_temp.events('admin', 'audit.log') e where e ->> 'action' = 'org.update'),
          'audit diteruskan ke pusat audit admin');
select ok((select updated_at is not null from market.organizations where id = (select id from t_ids where k = 'org_new')),
          'updated_at = tanda diajukan ulang (banner brand + detail admin)');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select lives_ok($$ select api.manage_org('44444444-0000-0000-0000-000000000002', 'verify') $$, 'admin_ops aal2 memverifikasi org');
select lives_ok($$ select api.manage_org('44444444-0000-0000-0000-000000000002', 'add_member',
                   '{"user_id":"11111111-0000-0000-0000-0000000000f1","role":"brand_manager","username":"pic_toko"}') $$,
                'admin menambah anggota paket managed');
reset role;
select is((select status::text from market.organizations where id = '44444444-0000-0000-0000-000000000002'), 'verified',
          'org2 verified (verified_by, verified_at)');
select is((select count(*)::int from pg_temp.events('admin', 'notify.user') e where e ->> 'event' = 'org.verified'
             and e ->> 'user_id' = '22222222-0000-0000-0000-0000000000a2' and e #>> '{payload,org_id}' = '44444444-0000-0000-0000-000000000002'), 1,
          'notifikasi org.verified ke brand_owner (event ke admin)');
select is((select (e -> 'payload') - 'reason' - 'message' from pg_temp.events('admin', 'notify.user') e where e ->> 'event' = 'org.verified'
             and e ->> 'user_id' = '22222222-0000-0000-0000-0000000000a2' and e #>> '{payload,org_id}' = '44444444-0000-0000-0000-000000000002'),
          '{"org_id":"44444444-0000-0000-0000-000000000002","org_name":"Toko Dua"}'::jsonb, 'payload org.*: org_id + org_name');
select is((select count(*)::int from pg_temp.events('admin', 'notify.user') e where e ->> 'event' = 'org.rejected'
             and e ->> 'user_id' = '22222222-0000-0000-0000-0000000000a2' and e #>> '{payload,reason}' = 'npwp_invalid'), 1,
          'notifikasi org.rejected + alasan');
select is((select array_agg(action order by id) from ops.audit_logs where target = 'org:44444444-0000-0000-0000-000000000002'),
          array['org.verify', 'org.add_member'], 'aksi manage_org tercatat di audit log');
select is((select e ->> 'username' from pg_temp.events('creator', 'profile.ensure') e where e ->> 'user_id' = '11111111-0000-0000-0000-0000000000f1'),
          'pic_toko', 'add_member: profil dipastikan di project profil dengan username pilihan admin');
select is((select role::text from market.org_members where user_id = '11111111-0000-0000-0000-0000000000f1'), 'brand_manager',
          'add_member: anggota dengan role');
select is((select count(*)::int from pg_temp.events('admin', 'review.decision') e where e ->> 'target_type' = 'org'), 3,
          'keputusan org dikirim ke E-19 admin');

-- Undangan anggota (token sekali tampil, hanya hash)
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select throws_ok($$ select api.create_org_invite('44444444-0000-0000-0000-000000000001', 'brand_viewer') $$, '42501', 'auth:forbidden',
                 'brand_manager tidak bisa membuat undangan');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
insert into t_ids (k, tok) select 'invite', api.create_org_invite('44444444-0000-0000-0000-000000000001', 'brand_viewer');
reset role;
select ok((select tok ~ '^[A-Za-z0-9_-]{43}$' from t_ids where k = 'invite'), 'token undangan 32 byte base64url');
select is((select count(*)::int from market.org_invites where token_hash = sha256(convert_to((select tok from t_ids where k = 'invite'), 'UTF8'))),
          1, 'yang disimpan hanya sha256 token');
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-0000000000f2');
select throws_ok($$ select api.accept_org_invite('salah') $$, 'P0002', 'not_found:invite', 'token tidak dikenal ditolak');
select is((select count(*)::int from api.invite_preview('salah')), 0, 'preview token tidak dikenal kosong');
select is((select row(role, expired, used)::text from api.invite_preview((select tok from t_ids where k = 'invite'))),
          '(brand_viewer,f,f)', 'preview undangan: role, belum kedaluwarsa, belum dipakai');
select is(api.accept_org_invite((select tok from t_ids where k = 'invite')), '44444444-0000-0000-0000-000000000001'::uuid,
          'penerima tanpa profil menerima undangan');
select pg_temp.jwt('11111111-0000-0000-0000-0000000000f3');
select throws_ok($$ select api.accept_org_invite((select tok from t_ids where k = 'invite')) $$, 'P0001', 'invite_used',
                 'token yang sudah dipakai ditolak');
select is((select used from api.invite_preview((select tok from t_ids where k = 'invite'))), true, 'preview: sudah dipakai');
reset role;
select is((select m.role::text from market.org_members m where m.user_id = '11111111-0000-0000-0000-0000000000f2'), 'brand_viewer',
          'anggota dengan role undangan');
select ok(exists (select 1 from pg_temp.events('creator', 'profile.ensure') e where e ->> 'user_id' = '11111111-0000-0000-0000-0000000000f2'),
          'profil penerima dipastikan di project profil');
update market.org_invites set accepted_by = null, accepted_at = null, created_at = now() - interval '8 days',
       expires_at = now() - interval '1 day';
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-0000000000f3');
select throws_ok($$ select api.accept_org_invite((select tok from t_ids where k = 'invite')) $$, 'P0001', 'invite_expired',
                 'token kedaluwarsa ditolak');
set local role anon;
select is((select expired from api.invite_preview((select tok from t_ids where k = 'invite'))), true, 'anon: preview kedaluwarsa');
reset role;

-- AB-5: brand_owner kelola anggota (ubah role, keluarkan, cabut undangan); org selalu punya ≥ 1 brand_owner
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select throws_ok($$ select api.manage_team('44444444-0000-0000-0000-000000000001', 'remove', '11111111-0000-0000-0000-0000000000f2') $$,
                 '42501', 'auth:forbidden', 'brand_manager tidak bisa mengelola anggota');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select lives_ok($$ select api.manage_team('44444444-0000-0000-0000-000000000001', 'set_role', '11111111-0000-0000-0000-0000000000f2',
                                          'brand_finance') $$, 'regresi AB-5: owner mengubah role anggota');
select throws_ok($$ select api.manage_team('44444444-0000-0000-0000-000000000001', 'set_role', '22222222-0000-0000-0000-0000000000a1',
                                           'brand_manager') $$, 'P0001', 'last_owner', 'owner terakhir tidak bisa turun role');
select throws_ok($$ select api.manage_team('44444444-0000-0000-0000-000000000001', 'remove', '22222222-0000-0000-0000-0000000000a1') $$,
                 'P0001', 'last_owner', 'owner terakhir tidak bisa dikeluarkan');
insert into t_ids (k, tok) select 'invite2', api.create_org_invite('44444444-0000-0000-0000-000000000001', 'brand_viewer');
reset role;
insert into t_ids (k, id) select 'invite2_id', id from market.org_invites
 where token_hash = sha256(convert_to((select tok from t_ids where k = 'invite2'), 'UTF8'));
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select lives_ok($$ select api.manage_team('44444444-0000-0000-0000-000000000001', 'revoke_invite', (select id from t_ids where k = 'invite2_id')) $$,
                'regresi AB-5: owner mencabut undangan yang belum dipakai');
select pg_temp.jwt('11111111-0000-0000-0000-0000000000f3');
select throws_ok($$ select api.accept_org_invite((select tok from t_ids where k = 'invite2')) $$, 'P0002', 'not_found:invite',
                 'link undangan yang dicabut tidak bisa dipakai');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select lives_ok($$ select api.manage_team('44444444-0000-0000-0000-000000000001', 'set_role', '11111111-0000-0000-0000-0000000000f2',
                                          'brand_owner') $$, 'owner menambah owner kedua');
select pg_temp.jwt('11111111-0000-0000-0000-0000000000f2');
insert into t_ids (k, tok) select 'invite_f2', api.create_org_invite('44444444-0000-0000-0000-000000000001', 'brand_owner');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select lives_ok($$ select api.manage_team('44444444-0000-0000-0000-000000000001', 'remove', '11111111-0000-0000-0000-0000000000f2') $$,
                'regresi AB-5: owner mengeluarkan anggota');
select pg_temp.jwt('11111111-0000-0000-0000-0000000000f3');
select throws_ok($$ select api.accept_org_invite((select tok from t_ids where k = 'invite_f2')) $$, 'P0002', 'not_found:invite',
                 'regresi R23-1: link undangan owner yang dikeluarkan ikut dicabut (bukan jalan kembali)');
select pg_temp.jwt('11111111-0000-0000-0000-0000000000f2');
select is((select count(*)::int from api.organizations where id = '44444444-0000-0000-0000-000000000001'), 0,
          'anggota yang dikeluarkan langsung kehilangan akses org');
reset role;
select ok(exists (select 1 from pg_temp.events('admin', 'org.owner_lost') e where e ->> 'user_id' = '11111111-0000-0000-0000-0000000000f2'
                    and e ->> 'org_id' = '44444444-0000-0000-0000-000000000001'),
          'regresi R25-1: owner hilang dikabarkan ke admin (refund dengan rekening pribadinya direset di admin)');
select is((select array_agg(action order by id) from ops.audit_logs where action like 'org.team.%'),
          array['org.team.set_role', 'org.team.revoke_invite', 'org.team.set_role', 'org.team.remove'], 'kelola anggota tercatat di audit');
-- R24-2: demosi owner lewat jalur admin (manage_org add_member) juga mencabut link undangan yang ia buat
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select api.manage_org('44444444-0000-0000-0000-000000000001', 'add_member',
                      '{"user_id":"11111111-0000-0000-0000-0000000000f3","role":"brand_owner","username":"own_f3"}');
select pg_temp.jwt('11111111-0000-0000-0000-0000000000f3');
insert into t_ids (k, tok) select 'invite_f3', api.create_org_invite('44444444-0000-0000-0000-000000000001', 'brand_owner');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select api.manage_org('44444444-0000-0000-0000-000000000001', 'add_member', '{"user_id":"11111111-0000-0000-0000-0000000000f3","role":"brand_viewer"}');
select pg_temp.jwt('11111111-0000-0000-0000-0000000000f2');
select throws_ok($$ select api.accept_org_invite((select tok from t_ids where k = 'invite_f3')) $$, 'P0002', 'not_found:invite',
                 'regresi R24-2: owner yang diturunkan admin tidak bisa kembali lewat link undangannya');
reset role;

-- Agency: request → approve (brand_owner klien) → revoke
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select throws_ok($$ select api.link_agency('44444444-0000-0000-0000-000000000001', '44444444-0000-0000-0000-000000000002', 'request') $$,
                 'P0001', 'not_agency', 'org biasa tidak bisa meminta tautan agency');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000e1');
select lives_ok($$ select api.link_agency('44444444-0000-0000-0000-0000000000a9', '44444444-0000-0000-0000-000000000001', 'request') $$,
                'agency meminta tautan ke klien');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select throws_ok($$ select api.link_agency('44444444-0000-0000-0000-0000000000a9', '44444444-0000-0000-0000-000000000001', 'approve') $$,
                 '42501', 'auth:forbidden', 'brand_manager klien tidak bisa menyetujui tautan');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select lives_ok($$ select api.link_agency('44444444-0000-0000-0000-0000000000a9', '44444444-0000-0000-0000-000000000001', 'approve') $$,
                'brand_owner klien menyetujui');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000e1');
select is((select count(*)::int from api.organizations where id = '44444444-0000-0000-0000-000000000001'), 1,
          'agency tertaut melihat org klien');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select lives_ok($$ select api.link_agency('44444444-0000-0000-0000-0000000000a9', '44444444-0000-0000-0000-000000000001', 'revoke') $$,
                'brand_owner klien mencabut');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000e1');
select is((select count(*)::int from api.organizations where id = '44444444-0000-0000-0000-000000000001'), 0,
          'tautan dicabut → akses hilang');
reset role;
select is((select approved_by from market.org_links), '22222222-0000-0000-0000-0000000000a1'::uuid, 'approved_by = brand_owner klien');
select is((select array_agg(e ->> 'event' order by e ->> 'event') from pg_temp.events('admin', 'notify.user') e where e ->> 'event' like 'agency.%'),
          array['agency.link_approved', 'agency.link_requested'], 'notifikasi tautan agency ke pihak terkait');
select ok(exists (select 1 from bus.outbox where target = 'admin' and topic = 'rep.row' and payload ->> 'table' = 'market.org_links'
                    and payload #>> '{row,revoked_at}' is not null), 'pencabutan tautan direplika ke admin (RLS campaign agency)');

-- Suspend org (F-A07)
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select throws_ok($$ select api.manage_org((select id from t_ids where k = 'org_new'), 'suspend') $$, 'P0001', 'invalid:reason',
                 'suspend org wajib alasan');
select lives_ok($$ select api.manage_org((select id from t_ids where k = 'org_new'), 'suspend', '{"reason":"chargeback"}') $$,
                'admin_ops suspend org');
reset role;
select is((select status::text from market.organizations where id = (select id from t_ids where k = 'org_new')), 'suspended', 'org disuspend');
select is((select count(*)::int from pg_temp.events('admin', 'notify.user') e where e ->> 'event' = 'org.suspended'
             and e ->> 'user_id' = '22222222-0000-0000-0000-0000000000a2'), 1, 'notifikasi org.suspended');
select ok(exists (select 1 from bus.outbox where target = 'creator' and topic = 'rep.row' and payload ->> 'table' = 'market.organizations'
                    and payload #>> '{row,status}' = 'suspended'), 'status suspend direplika ke creator');

select throws_ok($$ delete from market.org_members where user_id = '22222222-0000-0000-0000-0000000000a2'
                    and org_id = '44444444-0000-0000-0000-000000000002' $$, '23514', null, 'brand_owner terakhir tidak bisa dihapus');

-- ---------- akses ----------
select is((select count(*)::int from pg_proc p where p.pronamespace = 'api'::regnamespace
            and has_function_privilege('anon', p.oid, 'execute')), 1, 'anon hanya bisa invite_preview');
select ok(not has_function_privilege('authenticated', 'bus.emit(text, text, jsonb)', 'execute'), 'browser tidak bisa menulis outbox');

select * from finish();
rollback;
