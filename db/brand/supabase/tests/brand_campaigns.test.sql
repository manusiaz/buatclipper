-- test:brand.campaigns — isi campaign milik brand (F-B02 brief/syarat/aset, F-B10 duplikat isi, F-B11 undangan). Jadwal, pool,
-- rule, pengajuan diuji di admin (core_contracts_market). Status/jadwal tiba dari admin sebagai replika (bus_receive).
begin;
do $$ begin execute (select 'truncate ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' cascade'
  from pg_tables where schemaname in ('market', 'ops', 'bus')); end $$;
select no_plan();

create function pg_temp.jwt(p_sub text, p_roles text[] default '{}', p_aal text default 'aal1')
returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'aal', p_aal,
    'iss', 'https://auth.contoh.id/auth/v1', 'app_roles', to_jsonb(p_roles))::text, true);
$$;
grant execute on function pg_temp.jwt(text, text[], text) to anon, authenticated;
create temp table t_ids (k text primary key, id uuid, v int);
grant all on t_ids to anon, authenticated;
-- status/jadwal dari admin (replika)
create function pg_temp.admin_status(p_campaign uuid, p_status text) returns void language sql as $$
  select api.bus_receive('admin', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'topic', 'rep.row', 'payload',
    jsonb_build_object('table', 'market.campaigns', 'op', 'upsert', 'key', jsonb_build_object('id', p_campaign),
                       'row', jsonb_build_object('id', p_campaign, 'status', p_status)))));
$$;

insert into ops.settings (key, value) values ('auth.identity_issuer', '"https://auth.contoh.id/auth/v1"');
insert into market.categories (id, name_id, name_en) values ('games', 'Games', 'Games');
insert into market.profiles (id, username, display_name, status, trust_score) values
  ('22222222-0000-0000-0000-0000000000a1', 'owner1', 'Owner 1', 'active', 50),
  ('22222222-0000-0000-0000-0000000000b1', 'manager1', 'Manager 1', 'active', 50),
  ('11111111-0000-0000-0000-00000000000a', 'andi', 'Andi', 'active', 80),
  ('11111111-0000-0000-0000-00000000000b', 'budi', 'Budi', 'banned', 80);
insert into market.organizations (id, name, org_type, legal_name, npwp, address, status, verified_at, verified_by, created_by) values
  ('44444444-0000-0000-0000-000000000001', 'Studio Satu', 'badan', 'PT Studio Satu', '0123456789012345', 'Jakarta', 'verified', now(),
   '33333333-0000-0000-0000-0000000000ad', '22222222-0000-0000-0000-0000000000a1'),
  ('44444444-0000-0000-0000-000000000003', 'Toko Beku', 'perorangan', null, null, null, 'suspended', null, null, '22222222-0000-0000-0000-0000000000a1');
insert into market.org_members (org_id, user_id, role) values
  ('44444444-0000-0000-0000-000000000001', '22222222-0000-0000-0000-0000000000a1', 'brand_owner'),
  ('44444444-0000-0000-0000-000000000001', '22222222-0000-0000-0000-0000000000b1', 'brand_manager'),
  ('44444444-0000-0000-0000-000000000003', '22222222-0000-0000-0000-0000000000a1', 'brand_owner');
delete from bus.outbox;

-- ---------- simpan isi ----------
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Coba","type":"clipping",
                    "platforms":["tiktok"]}') $$, '42501', 'auth:forbidden', 'clipper tidak bisa membuat campaign');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal1');
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Coba","type":"clipping",
                    "platforms":["tiktok"]}') $$, '42501', 'auth:forbidden', 'builder admin butuh aal2');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000003","title":"Beku","type":"clipping",
                    "platforms":["tiktok"]}') $$, 'P0001', 'org_suspended', 'org disuspend tidak bisa membuat campaign');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Coba","type":"clipping",
                    "platforms":["tiktok"],"required_links":["http://studio.id"]}') $$, 'P0001', 'invalid:required_links',
                 'link brief wajib https');
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Coba","type":"clipping",
                    "platforms":["tiktok"],"status":"live"}') $$, 'P0001', 'invalid:unknown_key', 'status tidak bisa diisi dari builder');
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Coba","type":"clipping",
                    "platforms":["tiktok"],"start_at":"2099-01-01T00:00:00Z"}') $$, 'P0001', 'invalid:unknown_key',
                 'jadwal disimpan di admin (milik lifecycle)');
insert into t_ids (k, id, v) select 'c_new', (r ->> 'id')::uuid, (r ->> 'content_version')::int from api.save_campaign($j${
  "org_id":"44444444-0000-0000-0000-000000000001","title":"Film Baru Rilis","type":"clipping","category_id":"games",
  "platforms":["tiktok","instagram"],"brief":"Potong adegan terbaik.","required_hashtags":["#MPLID"," Clipper ","#mplid"],
  "required_mentions":["@StudioSatu"],"required_links":["studio.id/promo"],"dos":[" Pakai subtitle ",""],
  "faq":[{"q":"Boleh musik?","a":"Bebas lisensi"}]}$j$) r;
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Coba","type":"clipping",
                    "platforms":["tiktok"]}'::jsonb || jsonb_build_object('slug', (select slug from api.campaigns where id = (select id from t_ids where k = 'c_new')))) $$,
                 'P0001', 'slug_taken', 'slug unik');
select throws_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_new'), 'assets',
                    '[{"kind":"video","storage_path":"44444444-0000-0000-0000-000000000001/lain/x.mp4"}]'::jsonb)) $$,
                 'P0001', 'invalid:asset_path', 'file aset wajib di folder {org}/{campaign}/');
select lives_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_new'), 'assets',
                   jsonb_build_array(
                     jsonb_build_object('kind', 'cover', 'storage_path', '44444444-0000-0000-0000-000000000001/' || (select id from t_ids where k = 'c_new') || '/cover.webp'),
                     jsonb_build_object('kind', 'document', 'storage_path', '44444444-0000-0000-0000-000000000001/' || (select id from t_ids where k = 'c_new') || '/internal/brief.pdf'),
                     jsonb_build_object('kind', 'link', 'url', 'drive.example/folder')))) $$, 'aset brief disimpan');
reset role;
select is((select array[array_to_string(required_hashtags, ','), array_to_string(required_mentions, ','), array_to_string(required_links, ','),
                        array_to_string(dos, ','), status::text]
             from market.campaigns where id = (select id from t_ids where k = 'c_new')),
          array['mplid,clipper', 'studiosatu', 'https://studio.id/promo', 'Pakai subtitle', 'draft'],
          'brief dinormalisasi: hashtag/mention huruf kecil tanpa #/@, link https, kosong & duplikat dibuang');
select ok((select slug ~ '^film-baru-rilis-[0-9a-f]{6}$' from market.campaigns where id = (select id from t_ids where k = 'c_new')),
          'slug dibuat dari judul');
select is((select array_agg(kind || ':' || audience || ':' || coalesce(url, '-') order by kind) from market.campaign_assets
            where campaign_id = (select id from t_ids where k = 'c_new')),
          array['cover:clipper:-', 'document:internal:-', 'link:clipper:https://drive.example/folder'],
          'aset: berkas folder internal/ = audience internal, link jadi https');
select is((select v from t_ids where k = 'c_new'), 1, 'campaign baru: content_version 1 (dikembalikan ke builder)');
select is((select content_version from market.campaigns where id = (select id from t_ids where k = 'c_new')), 2,
          'aset berubah → versi naik (admin menunggu replika aset)');
select is((select seq > (select max(seq) from bus.outbox where payload ->> 'table' = 'market.campaign_assets') from bus.outbox
            where payload ->> 'table' = 'market.campaigns' and (payload #>> '{row,content_version}')::int = 2),
          true, 'versi baru dikirim setelah aset (urutan outbox)');
select is((select payload -> 'row' ->> 'title' from bus.outbox where target = 'admin' and topic = 'rep.row'
             and payload ->> 'table' = 'market.campaigns' and payload #>> '{key,id}' = (select id from t_ids where k = 'c_new')::text order by seq limit 1),
          'Film Baru Rilis', 'isi direplika ke admin');
select ok(not exists (select 1 from bus.outbox where payload ->> 'table' = 'market.campaigns' and payload -> 'row' ?| array['status', 'start_at']),
          'kolom milik admin (status, jadwal) tidak dikirim dari brand');
select is((select count(*)::int from bus.outbox where target = 'admin' and payload ->> 'table' = 'market.campaign_assets'), 3,
          'aset direplika ke admin');

-- versi isi: naik tiap isi berubah, FAQ saja tidak
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select is((select (api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_new'), 'title', 'Film Baru Rilis 2'))
                  ->> 'content_version')::int), 3, 'isi berubah → versi naik');
select is((select (api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_new'), 'faq',
                  '[{"q":"Durasi?","a":"15-60 detik"}]'::jsonb)) ->> 'content_version')::int), 3, 'FAQ saja tidak menaikkan versi');
reset role;

-- kunci brief: status dari admin (replika) in_review → hanya FAQ
select pg_temp.admin_status((select id from t_ids where k = 'c_new'), 'in_review');
select is((select status::text from market.campaigns where id = (select id from t_ids where k = 'c_new')), 'in_review',
          'status replika dari admin diterapkan (kolom parsial, baris sudah ada)');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select throws_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_new'),
                    'required_hashtags', '["baru"]'::jsonb)) $$, 'P0001', 'campaign_locked', 'brief terkunci sejak in_review');
select lives_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_new'),
                   'faq', '[{"q":"Boleh musik?","a":"Bebas lisensi"},{"q":"Durasi?","a":"15-60 detik"}]'::jsonb)) $$,
                'FAQ masih bisa ditambah sejak in_review');
reset role;
select throws_ok($$ update market.campaigns set brief = 'ganti' where id = (select id from t_ids where k = 'c_new') $$,
                 '23514', 'campaign_locked', 'trigger brief beku: pesan = kode campaign_locked (jalur mana pun)');
select pg_temp.admin_status((select id from t_ids where k = 'c_new'), 'rejected');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select is((select (api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_new'), 'brief', 'Brief diperbaiki'))
                  ->> 'content_version')::int), 4, 'ditolak admin → isi bisa diperbaiki (versi naik; admin mengembalikan ke draft)');
reset role;

-- ---------- duplikat (F-B10) ----------
select pg_temp.admin_status((select id from t_ids where k = 'c_new'), 'live');
update market.campaigns set start_at = now() - interval '1 day' where id = (select id from t_ids where k = 'c_new');
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.duplicate_campaign((select id from t_ids where k = 'c_new'), true) $$, '42501', 'auth:forbidden',
                 'clipper tidak bisa menduplikat');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
insert into t_ids (k, id) select 'c_dup', api.duplicate_campaign((select id from t_ids where k = 'c_new'), true);
reset role;
select is((select array[status::text, is_template::text, (start_at is null)::text, (slug <> (select slug from market.campaigns
             where id = (select id from t_ids where k = 'c_new')))::text, brief] from market.campaigns
            where id = (select id from t_ids where k = 'c_dup')), array['draft', 'true', 'true', 'true', 'Brief diperbaiki'],
          'duplikat = draft (template), tanpa jadwal, slug baru, isi sama');
select is((select count(*)::int from market.campaign_assets where campaign_id = (select id from t_ids where k = 'c_dup')), 0,
          'duplikat tanpa aset');

-- ---------- undangan (F-B11) ----------
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.invite_to_campaign((select id from t_ids where k = 'c_new'), array['andi']) $$, '42501', 'auth:forbidden',
                 'clipper tidak bisa mengundang');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select is(api.invite_to_campaign((select id from t_ids where k = 'c_new'), array['@Andi', 'tidakada', 'andi', 'budi']), 1,
          'undangan: username dinormalisasi, yang tidak ada / tidak aktif diabaikan');
select is(api.invite_to_campaign((select id from t_ids where k = 'c_new'), array['andi']), 0, 'undangan ulang tidak dihitung');
select throws_ok($$ select api.invite_to_campaign((select id from t_ids where k = 'c_dup'), array['andi']) $$, 'P0001',
                 'invalid_state:draft', 'template tidak menerima undangan');
reset role;
select is((select payload - 'campaign_slug' from bus.outbox where target = 'admin' and topic = 'notify.user' and payload ->> 'event' = 'campaign.invited'),
          jsonb_build_object('user_id', '11111111-0000-0000-0000-00000000000a', 'event', 'campaign.invited', 'email', true,
            'payload', jsonb_build_object('campaign_id', (select id from t_ids where k = 'c_new'), 'campaign_title', 'Film Baru Rilis 2',
              'campaign_slug', (select slug from market.campaigns where id = (select id from t_ids where k = 'c_new')),
              'org_id', '44444444-0000-0000-0000-000000000001', 'org_name', 'Studio Satu')),
          'notifikasi campaign.invited lewat admin (rate dilengkapi admin)');
select ok(exists (select 1 from bus.outbox where target = 'admin' and payload ->> 'table' = 'market.campaign_invites'),
          'undangan direplika ke admin (cek claim)');

-- ---------- visibilitas ----------
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select lives_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_dup'), 'is_template', false,
                   'visibility', 'invite')) $$, 'draft diubah jadi campaign undangan');
reset role;
select pg_temp.admin_status((select id from t_ids where k = 'c_dup'), 'live');
set local role anon;
select pg_temp.jwt('');
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is((select array_agg(title) from api.campaigns), array['Film Baru Rilis 2'], 'anon hanya campaign tayang publik');
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000b');
select is((select count(*)::int from api.campaigns where id = (select id from t_ids where k = 'c_dup')), 0, 'campaign undangan tertutup');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
reset role;
insert into market.campaign_invites (campaign_id, user_id, invited_by) values ((select id from t_ids where k = 'c_dup'),
  '11111111-0000-0000-0000-00000000000a', '22222222-0000-0000-0000-0000000000b1');
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select is((select count(*)::int from api.campaigns where id = (select id from t_ids where k = 'c_dup')), 1, 'yang diundang melihat');
select is((select count(*)::int from api.campaign_assets where audience = 'internal'), 0, 'berkas internal tidak terlihat clipper');
select is((select count(*)::int from api.managed_briefs), 0, 'brief mentah tidak terlihat clipper');
reset role;

-- ---------- storage (cover & aset campaign) ----------
insert into storage.buckets (id, name, public) values ('campaign-covers', 'campaign-covers', true), ('campaign-assets', 'campaign-assets', false)
  on conflict (id) do nothing;
insert into storage.objects (bucket_id, name) values
  ('campaign-assets', '44444444-0000-0000-0000-000000000001/' || (select id from t_ids where k = 'c_dup') || '/aset.mp4'),
  ('campaign-assets', '44444444-0000-0000-0000-000000000001/' || (select id from t_ids where k = 'c_dup') || '/internal/brief-brand.pdf');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('campaign-covers',
                   '44444444-0000-0000-0000-000000000001/' || (select id from t_ids where k = 'c_new') || '/cover.webp') $$,
                'brand_manager unggah cover ke folder org-nya');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('campaign-covers',
                    '44444444-0000-0000-0000-000000000001/' || (select id from t_ids where k = 'c_new') || '/x.webp') $$, '42501', null,
                 'bukan anggota org tidak bisa unggah ke folder org');
select is((select count(*)::int from storage.objects where bucket_id = 'campaign-assets'
           and name like '%/' || (select id from t_ids where k = 'c_dup') || '/%'), 1, 'file di folder internal/ tertutup untuk clipper');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select is((select count(*)::int from storage.objects where bucket_id = 'campaign-assets'
           and name like '%/' || (select id from t_ids where k = 'c_dup') || '/%'), 2, 'anggota org bisa membuka berkas internal');
reset role;

select * from finish();
rollback;
