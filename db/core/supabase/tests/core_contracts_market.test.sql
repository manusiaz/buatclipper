-- test:contracts.market — fungsi kontrak marketplace core (Lampiran A.3): org & tim, reward type, builder + invoice, kontrol,
-- daftar + claim (CTA 6 state), review & banding, read model, config, job budget-alerts / broadcast-dispatch / trust-score.
-- Jalankan: supabase test db --workdir db/core
begin;
-- Fixture tes tidak bergantung seed.sql (supabase db reset memuatnya sebelum supabase test db); di-rollback di akhir.
-- Stack lokal bisa berisi data uji manual: semua tabel domain + antrean pgmq dikosongkan dulu.
do $$ begin execute (select 'truncate ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' cascade'
  from pg_tables where schemaname in ('market', 'tracking', 'finance', 'trust', 'ops')
     or (schemaname = 'pgmq' and tablename like 'q\_%')); end $$;
select no_plan();

-- ---------- helper sesi (JWT identity) ----------
create function pg_temp.jwt(p_sub text, p_roles text[] default '{}', p_aal text default 'aal1', p_extra jsonb default '{}')
returns void language sql as $$
  select set_config('request.jwt.claims', (jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'aal', p_aal,
    'iss', 'https://auth.contoh.id/auth/v1', 'app_roles', to_jsonb(p_roles), 'kyc', 'none',
    'consent_ok', jsonb_build_object('clipper', true, 'brand', true)) || p_extra)::text, true);
$$;
create function pg_temp.anon() returns void language sql as $$
  select set_config('request.jwt.claims', '{"role":"anon"}', true);
$$;
grant execute on function pg_temp.jwt(text, text[], text, jsonb), pg_temp.anon() to anon, authenticated;
create temp table t_ids (k text primary key, id uuid, tok text);
grant all on t_ids to anon, authenticated;

-- ---------- data uji (sebagai postgres) ----------
insert into ops.settings (key, value) values
  ('auth.identity_issuer', '"https://auth.contoh.id/auth/v1"'),
  ('public.market.claim_hours', '48'),
  ('public.market.new_badge_days', '3'),
  ('public.billing.tax_pct', '11'),
  ('public.billing.pin_price_per_week_idr', '500000'),
  ('public.billing.managed_service_idr', '2500000'),
  ('public.billing.invoice_due_days', '7'),
  ('public.home.banners', '[]'),
  ('public.market.brand_review_auto_approve_hours', '72'),
  ('trust.score_deltas', '{"submission_approved":1,"submission_rejected":-2,"appeal_failed":-3}');
insert into market.profiles (id, username, display_name, trust_score, status, suspended_until) values
  ('11111111-0000-0000-0000-00000000000a', 'andi', 'Andi', 60, 'active', null),
  ('11111111-0000-0000-0000-00000000000b', 'budi', 'Budi', 40, 'active', null),
  ('11111111-0000-0000-0000-00000000000c', 'citra', 'Citra', 60, 'active', null),
  ('11111111-0000-0000-0000-00000000000d', 'dodi', 'Dodi', 60, 'suspended', now() + interval '30 days'),
  ('11111111-0000-0000-0000-00000000000e', 'eko', 'Eko', 70, 'active', null),
  ('22222222-0000-0000-0000-0000000000a1', 'owner1', 'Owner 1', 50, 'active', null),
  ('22222222-0000-0000-0000-0000000000b1', 'manager1', 'Manager 1', 50, 'active', null),
  ('22222222-0000-0000-0000-0000000000c1', 'finance1', 'Finance 1', 50, 'active', null),
  ('22222222-0000-0000-0000-0000000000a2', 'owner2', 'Owner 2', 50, 'active', null),
  ('22222222-0000-0000-0000-0000000000e1', 'agency1', 'Agency 1', 50, 'active', null),
  ('33333333-0000-0000-0000-0000000000ad', 'adminops', 'Admin', 50, 'active', null);
insert into finance.fee_rules (id, scope, mgmt_fee_pct, admin_fee_pct, clipper_fee_pct, instant_withdraw_fee) values
  ('f0000000-0000-0000-0000-000000000000', 'global', 15, 5, 0, 5000);
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
  ('44444444-0000-0000-0000-000000000001', '22222222-0000-0000-0000-0000000000c1', 'brand_finance'),
  ('44444444-0000-0000-0000-000000000002', '22222222-0000-0000-0000-0000000000a2', 'brand_owner'),
  ('44444444-0000-0000-0000-0000000000a9', '22222222-0000-0000-0000-0000000000e1', 'brand_owner');
insert into market.categories (id, name_id, name_en) values ('games', 'Game', 'Games'), ('music', 'Musik', 'Music');
insert into market.reward_types (id, owner_org_id, code, name, kind, unit_label, idr_value_per_unit, fulfillment) values
  ('77777777-0000-0000-0000-000000000001', null, 'IDR', 'Rupiah', 'cash', 'Rp', 1, 'payout'),
  ('77777777-0000-0000-0000-000000000002', '44444444-0000-0000-0000-000000000001', 'DM', 'Diamonds', 'in_game', 'Diamonds', 250,
   'manual_export');
insert into tracking.social_accounts (id, user_id, platform, external_id, handle, followers, platform_created_at) values
  ('99999999-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'tiktok', 'tt-a', '@andi', 5000, now() - interval '730 days'),
  ('99999999-0000-0000-0000-000000000002', '11111111-0000-0000-0000-00000000000b', 'tiktok', 'tt-b', '@budi', 100, now() - interval '10 days'),
  ('99999999-0000-0000-0000-000000000004', '11111111-0000-0000-0000-00000000000d', 'tiktok', 'tt-d', '@dodi', 5000, now() - interval '730 days'),
  ('99999999-0000-0000-0000-000000000005', '11111111-0000-0000-0000-00000000000e', 'tiktok', 'tt-e', '@eko', 2000, now() - interval '400 days');

-- Campaign tayang org1 (tiktok, pool IDR + rule Rp2.000/1.000 views). Kolom yang beda per campaign = skenario CTA.
do $$
declare
  r record;
begin
  for r in select * from (values
    ('01', 'film-satu',       'Film Satu',        1000, null::int, 10, 'manual', 'public', 0,  false, 0,  'live',   1, 14,   1000000, 0),
    ('02', 'slot-penuh',      'Slot Penuh',       0,    1,         10, 'manual', 'public', 0,  false, 0,  'live',   1, 14,   1000000, 0),
    ('03', 'budget-habis',    'Budget Habis',     0,    null,      10, 'manual', 'public', 0,  false, 0,  'live',   1, 14,   500000,  500000),
    ('04', 'deadline-lewat',  'Deadline Lewat',   0,    null,      10, 'manual', 'public', 0,  false, 0,  'live',   10, -1,  1000000, 0),
    ('05', 'follower-tinggi', 'Follower Tinggi',  100000, null,    10, 'manual', 'public', 0,  false, 0,  'live',   1, 14,   1000000, 0),
    ('06', 'maks-klip',       'Maks Klip',        0,    null,      1,  'manual', 'public', 0,  false, 0,  'live',   10, 20,  1000000, 50000),
    ('07', 'review-brand',    'Review Brand',     0,    null,      10, 'brand',  'public', 0,  false, 0,  'live',   5, 14,   1000000, 0),
    ('08', 'undangan',        'Khusus Undangan',  0,    null,      10, 'manual', 'invite', 0,  false, 0,  'live',   1, 14,   1000000, 0),
    ('09', 'kyc-wajib',       'KYC Wajib',        0,    null,      10, 'manual', 'public', 0,  true,  0,  'live',   1, 14,   1000000, 0),
    ('0a', 'umur-akun',       'Umur Akun',        0,    null,      10, 'manual', 'public', 0,  false, 30, 'live',   1, 14,   1000000, 0),
    ('0b', 'trust-limapuluh', 'Trust Lima Puluh', 0,    null,      10, 'manual', 'public', 50, false, 0,  'live',   1, 14,   1000000, 0),
    ('0c', 'dijeda',          'Dijeda',           0,    null,      10, 'manual', 'public', 0,  false, 0,  'paused', 1, 14,   1000000, 0),
    ('0d', 'level-tujuh',     'Level Tujuh Puluh', 0,   null,      10, 'manual', 'level',  70, false, 0,  'live',   1, 14,   1000000, 0)
  ) v(sfx, slug, title, min_followers, quota, max_clips, review_mode, visibility, min_trust, kyc, min_age, target, started, deadline,
      total, allocated)
  loop
    insert into market.campaigns (id, org_id, slug, title, type, category_id, platforms, required_hashtags, start_at, submit_deadline,
                                  min_followers, clipper_quota, max_clips_per_clipper, review_mode, visibility, min_trust_score,
                                  kyc_required, min_account_age_days, created_by)
    values (('55555555-0000-0000-0000-0000000000' || r.sfx)::uuid, '44444444-0000-0000-0000-000000000001', r.slug, r.title,
            'clipping', 'games', '{tiktok}', '{mplid}', now() - make_interval(days => r.started),
            now() + make_interval(days => r.deadline),
            r.min_followers, r.quota, r.max_clips, r.review_mode, r.visibility, r.min_trust, r.kyc, r.min_age,
            '22222222-0000-0000-0000-0000000000a1');
    insert into finance.reward_pools (id, campaign_id, reward_type_id, total, allocated, max_per_clip)
    values (('66666666-0000-0000-0000-0000000000' || r.sfx)::uuid, ('55555555-0000-0000-0000-0000000000' || r.sfx)::uuid,
            '77777777-0000-0000-0000-000000000001', r.total, r.allocated, 100000);
    insert into market.rate_rules (id, campaign_id, kind, reward_type_id, pool_id, params)
    values (('67676767-0000-0000-0000-0000000000' || r.sfx)::uuid, ('55555555-0000-0000-0000-0000000000' || r.sfx)::uuid,
            'per_1k_views', '77777777-0000-0000-0000-000000000001', ('66666666-0000-0000-0000-0000000000' || r.sfx)::uuid,
            '{"rate": 2000}');
    update market.campaigns set status = 'in_review' where id = ('55555555-0000-0000-0000-0000000000' || r.sfx)::uuid;
    update market.campaigns set status = 'scheduled' where id = ('55555555-0000-0000-0000-0000000000' || r.sfx)::uuid;
    update market.campaigns set status = 'live' where id = ('55555555-0000-0000-0000-0000000000' || r.sfx)::uuid;
    if r.target = 'paused' then
      update market.campaigns set status = 'paused' where id = ('55555555-0000-0000-0000-0000000000' || r.sfx)::uuid;
    end if;
  end loop;
end $$;
-- Draft & template org1 (tidak terlihat clipper)
insert into market.campaigns (id, org_id, slug, title, type, platforms, created_by, is_template) values
  ('55555555-0000-0000-0000-0000000000d1', '44444444-0000-0000-0000-000000000001', 'draft-satu', 'Draft Satu', 'clipping', '{tiktok}',
   '22222222-0000-0000-0000-0000000000a1', false),
  ('55555555-0000-0000-0000-0000000000f1', '44444444-0000-0000-0000-000000000001', 'template-satu', 'Template Satu', 'clipping',
   '{tiktok}', '22222222-0000-0000-0000-0000000000a1', true);

-- Claim & submisi awal: Budi memegang slot satu-satunya di slot-penuh; Andi sudah 1 klip (tracking) di maks-klip.
insert into market.claims (id, campaign_id, user_id, expires_at) values
  ('88888888-0000-0000-0000-000000000002', '55555555-0000-0000-0000-000000000002', '11111111-0000-0000-0000-00000000000b', now() + interval '40 hours'),
  ('88888888-0000-0000-0000-000000000006', '55555555-0000-0000-0000-000000000006', '11111111-0000-0000-0000-00000000000a', now() + interval '40 hours');
insert into tracking.submissions (id, claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at) values
  ('aaaaaaaa-0000-0000-0000-000000000006', '88888888-0000-0000-0000-000000000006', '11111111-0000-0000-0000-00000000000a',
   '55555555-0000-0000-0000-000000000006', '99999999-0000-0000-0000-000000000001', 'tiktok', 'v6', 'https://tiktok.com/@andi/video/6',
   now() - interval '3 days');
update market.claims set status = 'submitted' where id = '88888888-0000-0000-0000-000000000006';
update tracking.submissions set status = 'tracking', counted_views = 25000 where id = 'aaaaaaaa-0000-0000-0000-000000000006';
insert into tracking.view_snapshots (submission_id, taken_at, views, likes) values
  ('aaaaaaaa-0000-0000-0000-000000000006', now() - interval '2 days', 10000, 500),
  ('aaaaaaaa-0000-0000-0000-000000000006', now() - interval '1 day', 25000, 1200);

-- Campaign tambahan untuk end_early (Eko memegang claim terbuka) + aset campaign film-satu.
insert into market.campaigns (id, org_id, slug, title, type, platforms, start_at, submit_deadline, created_by) values
  ('55555555-0000-0000-0000-00000000000e', '44444444-0000-0000-0000-000000000001', 'diakhiri', 'Diakhiri Awal', 'clipping', '{tiktok}',
   now() - interval '1 day', now() + interval '14 days', '22222222-0000-0000-0000-0000000000a1');
update market.campaigns set status = 'in_review' where id = '55555555-0000-0000-0000-00000000000e';
update market.campaigns set status = 'scheduled' where id = '55555555-0000-0000-0000-00000000000e';
update market.campaigns set status = 'live' where id = '55555555-0000-0000-0000-00000000000e';
insert into market.claims (id, campaign_id, user_id, expires_at) values
  ('88888888-0000-0000-0000-00000000000e', '55555555-0000-0000-0000-00000000000e', '11111111-0000-0000-0000-00000000000e', now() + interval '40 hours');
insert into market.campaign_assets (campaign_id, kind, storage_path, url, audience) values
  ('55555555-0000-0000-0000-000000000001', 'cover', '44444444-0000-0000-0000-000000000001/55555555-0000-0000-0000-000000000001/cover.webp', null, 'clipper'),
  ('55555555-0000-0000-0000-000000000001', 'link', null, 'https://drive.example/aset', 'clipper'),
  ('55555555-0000-0000-0000-000000000001', 'document', '44444444-0000-0000-0000-000000000001/55555555-0000-0000-0000-000000000001/internal/brief.pdf', null, 'internal');

-- Submisi untuk review: Andi/Eko/Budi di review-brand (Budi 73 jam lalu = lewat batas auto-approve); Eko & Dodi di campaign
-- review manual (lama); Budi sudah ditolak + sudah banding di film-satu.
insert into market.claims (id, campaign_id, user_id, expires_at, created_at) values
  ('88888888-0000-0000-0000-000000000071', '55555555-0000-0000-0000-000000000007', '11111111-0000-0000-0000-00000000000a', now() + interval '40 hours', now() - interval '5 hours'),
  ('88888888-0000-0000-0000-000000000072', '55555555-0000-0000-0000-000000000007', '11111111-0000-0000-0000-00000000000e', now() + interval '40 hours', now() - interval '5 hours'),
  ('88888888-0000-0000-0000-000000000073', '55555555-0000-0000-0000-000000000007', '11111111-0000-0000-0000-00000000000b', now() + interval '40 hours', now() - interval '80 hours'),
  ('88888888-0000-0000-0000-000000000075', '55555555-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000e', now() + interval '40 hours', now() - interval '110 hours'),
  ('88888888-0000-0000-0000-000000000076', '55555555-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000b', now() + interval '40 hours', now() - interval '110 hours'),
  ('88888888-0000-0000-0000-000000000077', '55555555-0000-0000-0000-000000000005', '11111111-0000-0000-0000-00000000000d', now() + interval '40 hours', now() - interval '110 hours');
insert into tracking.submissions (id, claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at, created_at)
select ('aaaaaaaa-0000-0000-0000-0000000000' || x.sfx)::uuid, ('88888888-0000-0000-0000-0000000000' || x.sfx)::uuid, cl.user_id,
       cl.campaign_id, a.id, 'tiktok', 'v' || x.sfx, 'https://tiktok.com/v/' || x.sfx, now() - x.age, now() - x.age
  from (values ('71', interval '1 hour'), ('72', interval '2 hours'), ('73', interval '73 hours'), ('75', interval '100 hours'),
               ('76', interval '100 hours'), ('77', interval '100 hours')) x(sfx, age)
  join market.claims cl on cl.id = ('88888888-0000-0000-0000-0000000000' || x.sfx)::uuid
  join tracking.social_accounts a on a.user_id = cl.user_id and a.platform = 'tiktok';
update market.claims set status = 'submitted' where id::text like '88888888-0000-0000-0000-00000000007%';
update tracking.submissions set status = 'in_review' where id::text like 'aaaaaaaa-0000-0000-0000-00000000007%' and id <> 'aaaaaaaa-0000-0000-0000-000000000076';
update tracking.submissions set status = 'rejected' where id = 'aaaaaaaa-0000-0000-0000-000000000076';
insert into trust.review_decisions (target_type, target_id, actor_id, decision, message) values
  ('submission', 'aaaaaaaa-0000-0000-0000-000000000076', '11111111-0000-0000-0000-00000000000b', 'appeal', 'cek lagi');

-- Saldo Andi (pending Rp50.000 dari pool maks-klip) untuk my_stats; Andi mematikan email promosi.
insert into finance.ledger_accounts (id, owner_type, owner_id, reward_type_id) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'campaign_pool', '66666666-0000-0000-0000-000000000006', '77777777-0000-0000-0000-000000000001'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'user_wallet', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000001');
insert into finance.ledger_entries (txn_id, account_id, reward_type_id, amount, state, ref_type, ref_id) values
  ('cccccccc-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', '77777777-0000-0000-0000-000000000001', -50000, null, 'accrual', '1:r1'),
  ('cccccccc-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002', '77777777-0000-0000-0000-000000000001', 50000, 'pending', 'accrual', '1:r1');
insert into ops.notification_prefs (user_id, email_promotions) values ('11111111-0000-0000-0000-00000000000a', false);
create temp table t_json (k text primary key, j jsonb);
grant all on t_json to anon, authenticated;

-- ---------- struktur ----------
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p
            where p.pronamespace = 'api'::regnamespace
              and p.proname in ('list_campaigns', 'claim_campaign', 'appeal_submission', 'save_campaign', 'control_campaign',
                                'duplicate_campaign', 'invite_to_campaign', 'create_org', 'link_agency', 'create_org_invite',
                                'accept_org_invite', 'invite_preview', 'manage_org', 'save_reward_type', 'upload_reward_codes', 'buy_pin',
                                'record_review', 'update_config', 'send_broadcast', 'campaign_detail', 'campaign_stats', 'my_stats')
              and not (p.prosecdef and p.proconfig @> array['search_path=""'])), null,
          'semua fungsi kontrak marketplace: security definer + search_path kosong');
select is((select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p
            where p.proname in ('fail', 'session_uid', 'notify_org', 'campaign_visible', 'claim_check', 'campaign_budget', 'issue_invoice',
                                'next_invoice_number', 'apply_submission_decision', 'auto_approve_overdue', 'recalc_scores',
                                'run_budget_alerts', 'dispatch_broadcasts', 'campaign_report', 'campaign_projection', 'decide_org',
                                'ensure_member_profile', 'create_fee_rule')
              and p.pronamespace in ('market'::regnamespace, 'finance'::regnamespace, 'trust'::regnamespace, 'ops'::regnamespace)
              and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))),
          null, 'helper internal (invoice, keputusan, job) tidak bisa dipanggil browser');

-- ---------- org & tim (F-B01, F-B12, F-A07) ----------
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2', p_extra => '{"consent_ok":{"clipper":true,"brand":false}}');
select throws_ok($$ select api.create_org('Brand Baru', 'perorangan') $$, 'P0001', 'consent_required:brand',
                 'create_org butuh consent_ok.brand');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2');
select throws_ok($$ select api.create_org('PT Baru', 'badan', 'PT Baru Jaya', '123', 'Jakarta') $$, 'P0001', 'invalid:npwp',
                 'badan usaha wajib NPWP 15/16 digit');
select throws_ok($$ select api.create_org('Toko Tiga', 'perorangan', null, '3171012345670001') $$, 'P0001', 'invalid:perorangan_pii',
                 'org perorangan tidak menyimpan NIK/alamat di core');
select throws_ok($$ select api.create_org('PT Tanpa Alamat', 'badan', 'PT Tanpa Alamat', '012345678901234') $$, 'P0001', 'invalid:address',
                 'regresi AB-12: badan usaha wajib alamat (dipakai di faktur)');
insert into t_ids (k, id) select 'org_new', api.create_org('PT Baru', 'badan', 'PT Baru Jaya', '01.234.567.8-901.234', 'Jakarta');
reset role;
select is((select status::text || ':' || npwp from market.organizations where id = (select id from t_ids where k = 'org_new')),
          'pending_verification:012345678901234', 'org baru pending_verification, NPWP dinormalisasi angka');
select is((select role::text from market.org_members where org_id = (select id from t_ids where k = 'org_new')
             and user_id = '22222222-0000-0000-0000-0000000000a2'), 'brand_owner', 'pembuat org = brand_owner');

-- manage_org: admin_ops aal1 ditolak; aal2 verify → verified + review + notifikasi + audit
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
select ok((select updated_at is not null from market.organizations where id = (select id from t_ids where k = 'org_new')),
          'updated_at = tanda diajukan ulang (banner brand + detail admin)');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select lives_ok($$ select api.manage_org('44444444-0000-0000-0000-000000000002', 'verify') $$, 'admin_ops aal2 memverifikasi org');
select lives_ok($$ select api.manage_org('44444444-0000-0000-0000-000000000002', 'set_fee', '{"mgmt_fee_pct": 10}') $$,
                'admin_ops memasang fee custom org');
select lives_ok($$ select api.manage_org('44444444-0000-0000-0000-000000000002', 'add_member',
                   '{"user_id":"11111111-0000-0000-0000-0000000000f1","role":"brand_manager","username":"pic_toko"}') $$,
                'admin menambah anggota paket managed (profil dibuat)');
reset role;
select is((select status::text from market.organizations where id = '44444444-0000-0000-0000-000000000002'), 'verified',
          'org2 verified (verified_by, verified_at)');
select is((select count(*)::int from ops.notifications where event = 'org.verified' and user_id = '22222222-0000-0000-0000-0000000000a2'
             and payload ->> 'org_id' = '44444444-0000-0000-0000-000000000002'), 1,
          'notifikasi org.verified ke brand_owner');
select is((select payload - 'reason' - 'message' from ops.notifications where event = 'org.verified'
             and user_id = '22222222-0000-0000-0000-0000000000a2' and payload ->> 'org_id' = '44444444-0000-0000-0000-000000000002'),
          '{"org_id":"44444444-0000-0000-0000-000000000002","org_name":"Toko Dua"}'::jsonb, 'payload org.*: org_id + org_name');
select is((select count(*)::int from ops.notifications where event = 'org.rejected' and user_id = '22222222-0000-0000-0000-0000000000a2'
             and payload ->> 'reason' = 'npwp_invalid'), 1, 'notifikasi org.rejected + alasan');
select is((select array_agg(action order by id) from ops.audit_logs where target = 'org:44444444-0000-0000-0000-000000000002'),
          array['org.verify', 'org.set_fee', 'org.add_member'], 'aksi manage_org tercatat di audit log');
select is((select f.mgmt_fee_pct from market.organizations o join finance.fee_rules f on f.id = o.fee_rule_id
            where o.id = '44444444-0000-0000-0000-000000000002'), 10.00::numeric, 'fee rule org baru (scope org) terpasang');
select is((select p.username || ':' || m.role from market.profiles p join market.org_members m on m.user_id = p.id
            where p.id = '11111111-0000-0000-0000-0000000000f1'), 'pic_toko:brand_manager', 'add_member membuat profil + anggota');
select is((select count(*)::int from trust.review_decisions where target_type = 'org'), 3, 'keputusan org tercatat di E-19');

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
select is((select m.role::text from market.org_members m join market.profiles p on p.id = m.user_id
            where m.user_id = '11111111-0000-0000-0000-0000000000f2' and p.username = 'm_111111110000'), 'brand_viewer',
          'profil dibuat dulu (username sementara) lalu anggota dengan role undangan');
update market.org_invites set accepted_by = null, accepted_at = null, created_at = now() - interval '8 days',
       expires_at = now() - interval '1 day';
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-0000000000f3');
select throws_ok($$ select api.accept_org_invite((select tok from t_ids where k = 'invite')) $$, 'P0001', 'invite_expired',
                 'token kedaluwarsa ditolak');
set local role anon;
select is((select expired from api.invite_preview((select tok from t_ids where k = 'invite'))), true, 'anon: preview kedaluwarsa');
set local role authenticated;
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

-- Agency: request → approve (brand_owner klien) → akses → revoke
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select throws_ok($$ select api.link_agency('44444444-0000-0000-0000-000000000001', '44444444-0000-0000-0000-000000000002', 'request') $$,
                 'P0001', 'not_agency', 'org biasa tidak bisa meminta tautan agency');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000e1');
select lives_ok($$ select api.link_agency('44444444-0000-0000-0000-0000000000a9', '44444444-0000-0000-0000-000000000001', 'request') $$,
                'agency meminta tautan ke klien');
select is((select count(*)::int from api.campaigns where org_id = '44444444-0000-0000-0000-000000000001' and status = 'draft'), 0,
          'sebelum disetujui agency tidak melihat draft klien');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select throws_ok($$ select api.link_agency('44444444-0000-0000-0000-0000000000a9', '44444444-0000-0000-0000-000000000001', 'approve') $$,
                 '42501', 'auth:forbidden', 'brand_manager klien tidak bisa menyetujui tautan');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select lives_ok($$ select api.link_agency('44444444-0000-0000-0000-0000000000a9', '44444444-0000-0000-0000-000000000001', 'approve') $$,
                'brand_owner klien menyetujui');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000e1');
select is((select count(*)::int from api.campaigns where org_id = '44444444-0000-0000-0000-000000000001' and status = 'draft'), 2,
          'agency tertaut melihat draft & template klien');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select lives_ok($$ select api.link_agency('44444444-0000-0000-0000-0000000000a9', '44444444-0000-0000-0000-000000000001', 'revoke') $$,
                'brand_owner klien mencabut');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000e1');
select is((select count(*)::int from api.campaigns where org_id = '44444444-0000-0000-0000-000000000001' and status = 'draft'), 0,
          'tautan dicabut → akses hilang');
reset role;
select is((select approved_by from market.org_links), '22222222-0000-0000-0000-0000000000a1'::uuid, 'approved_by = brand_owner klien');

-- ---------- reward type & kode voucher (F-B03) ----------
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2');
select throws_ok($$ select api.save_reward_type('{"owner_org_id":"44444444-0000-0000-0000-000000000001","code":"X","name":"X",
                    "kind":"points","unit_label":"poin","idr_value_per_unit":1,"fulfillment":"manual_export"}') $$, '42501', 'auth:forbidden',
                 'org lain tidak bisa membuat reward type org1');
select throws_ok($$ select api.save_reward_type('{"code":"GLOBAL","name":"G","kind":"points","unit_label":"poin",
                    "idr_value_per_unit":1,"fulfillment":"manual_export"}') $$, '42501', 'auth:forbidden',
                 'reward type global hanya admin_super');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
insert into t_ids (k, id) select 'rt_voucher', api.save_reward_type('{"owner_org_id":"44444444-0000-0000-0000-000000000001",
  "code":"vcr50","name":"Voucher 50rb","kind":"voucher_code","unit_label":"voucher","idr_value_per_unit":50000,"fulfillment":"code_pool"}');
insert into t_ids (k, id) select 'rt_hook', api.save_reward_type('{"owner_org_id":"44444444-0000-0000-0000-000000000001",
  "code":"GEM","name":"Gem","kind":"in_game","unit_label":"Gem","idr_value_per_unit":100,"fulfillment":"webhook",
  "webhook_url":"https://game.example/hook","webhook_secret":"rahasia-hmac"}');
select is(api.upload_reward_codes((select id from t_ids where k = 'rt_voucher'), array['A1', 'A2', 'A1', ' ', 'A3 ']), 3,
          'kode duplikat & kosong diabaikan');
select is(api.upload_reward_codes((select id from t_ids where k = 'rt_voucher'), array['A3', 'A4']), 1, 'kode yang sudah ada diabaikan');
select throws_ok($$ select api.upload_reward_codes('77777777-0000-0000-0000-000000000002', array['X']) $$, 'P0001', 'invalid:fulfillment',
                 'kode hanya untuk reward type code_pool');
reset role;
select is((select code from market.reward_types where id = (select id from t_ids where k = 'rt_voucher')), 'VCR50', 'kode reward type huruf besar');
select is((select s.decrypted_secret from market.reward_types r join vault.decrypted_secrets s on s.id = r.webhook_secret_ref
            where r.id = (select id from t_ids where k = 'rt_hook')), 'rahasia-hmac', 'secret webhook disimpan di Vault (ref di tabel)');

-- ---------- builder (F-B02, F-A03) + invoice (§5.2) + review campaign (F-A02) ----------
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Coba","type":"clipping",
                    "platforms":["tiktok"]}') $$, '42501', 'auth:forbidden', 'clipper tidak bisa membuat campaign');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal1');
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Coba","type":"clipping",
                    "platforms":["tiktok"]}') $$, '42501', 'auth:forbidden', 'builder admin butuh aal2');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Coba","type":"clipping",
                    "platforms":["tiktok"],"required_links":["http://studio.id"]}') $$, 'P0001', 'invalid:required_links',
                 'link brief wajib https');
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Coba","type":"clipping",
                    "platforms":["tiktok"],"status":"live"}') $$, 'P0001', 'invalid:unknown_key', 'status tidak bisa diisi dari builder');
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Coba","type":"clipping",
                    "platforms":["tiktok"],"fee_rule":{"mgmt_fee_pct":1}}') $$, '42501', 'auth:forbidden', 'brand tidak bisa override fee');
select throws_ok($$ select api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Coba","type":"clipping",
                    "platforms":["tiktok"],"slug":"film-satu"}') $$, 'P0001', 'slug_taken', 'slug unik');
insert into t_ids (k, id) select 'c_new', api.save_campaign($j${
  "org_id":"44444444-0000-0000-0000-000000000001","title":"Film Baru Rilis","type":"clipping","category_id":"games",
  "platforms":["tiktok","instagram"],"brief":"Potong adegan terbaik.","required_hashtags":["#MPLID"," Clipper ","#mplid"],
  "required_mentions":["@StudioSatu"],"required_links":["studio.id/promo"],"dos":[" Pakai subtitle ",""],
  "faq":[{"q":"Boleh musik?","a":"Bebas lisensi"}],
  "pools":[{"key":"idr","reward_type_id":"77777777-0000-0000-0000-000000000001","total":10000000,"max_per_clip":1000000}],
  "rules":[{"kind":"per_1k_views","pool":"idr","platform":"tiktok","params":{"rate":2000}},
           {"kind":"per_1k_views","pool":"idr","platform":"instagram","params":{"rate":2500}}]}$j$::jsonb
  || jsonb_build_object('start_at', now() + interval '1 day', 'submit_deadline', now() + interval '15 days'));
select throws_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_new'), 'rules',
                    '[{"kind":"per_1k_views","pool_id":"66666666-0000-0000-0000-000000000001","params":{"rate":0}}]'::jsonb)) $$,
                 'P0001', 'invalid:rule_params', 'parameter rate rule divalidasi per kind');
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
select is((select array_agg(r.platform::text || ':' || (r.params ->> 'rate') order by r.platform) from market.rate_rules r
            where r.campaign_id = (select id from t_ids where k = 'c_new')), array['tiktok:2000', 'instagram:2500'],
          'rate rule per platform menunjuk pool yang sama');
select is((select array_agg(kind || ':' || audience || ':' || coalesce(url, '-') order by kind) from market.campaign_assets
            where campaign_id = (select id from t_ids where k = 'c_new')),
          array['cover:clipper:-', 'document:internal:-', 'link:clipper:https://drive.example/folder'],
          'aset: berkas folder internal/ = audience internal, link jadi https');

-- Submit: org belum verified ditolak; org1 → in_review + invoice campaign (§5.2) + invoice.issued
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2');
select throws_ok($$ select api.save_campaign(jsonb_build_object('org_id', (select id from t_ids where k = 'org_new')) || $j${"title":"Belum Verified",
                    "type":"ugc","platforms":["tiktok"],"pools":[{"key":"p","reward_type_id":"77777777-0000-0000-0000-000000000001",
                    "total":1000000,"max_per_clip":10000}],"rules":[{"kind":"flat_per_post","pool":"p","params":{"amount":25000}}]}$j$::jsonb
                    || jsonb_build_object('start_at', now() + interval '1 day', 'submit_deadline', now() + interval '9 days'), true) $$,
                 'P0001', 'org_not_verified', 'org belum diverifikasi tidak bisa mengajukan');
insert into t_ids (k, id) select 'c_org2', api.save_campaign($j${"org_id":"44444444-0000-0000-0000-000000000002","title":"Toko Dua Promo",
  "type":"ugc","platforms":["tiktok"],"pools":[{"key":"p","reward_type_id":"77777777-0000-0000-0000-000000000001","total":2000000,
  "max_per_clip":10000}],"rules":[{"kind":"flat_per_post","pool":"p","params":{"amount":25000}}]}$j$::jsonb
  || jsonb_build_object('start_at', now() + interval '1 day', 'submit_deadline', now() + interval '9 days'), true);
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select lives_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_new')), true) $$,
                'brand_manager mengajukan campaign');
select throws_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_new'),
                    'required_hashtags', '["baru"]'::jsonb)) $$, 'P0001', 'campaign_locked', 'brief terkunci sejak in_review');
select lives_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_new'),
                   'faq', '[{"q":"Boleh musik?","a":"Bebas lisensi"},{"q":"Durasi?","a":"15-60 detik"}]'::jsonb)) $$,
                'FAQ masih bisa ditambah sejak in_review');
select throws_ok($$ select api.save_campaign('{"id":"55555555-0000-0000-0000-0000000000f1"}', true) $$, 'P0001', 'invalid:template',
                 'template tidak bisa diajukan');
reset role;
select is((select status::text || ':' || jsonb_array_length(faq) from market.campaigns where id = (select id from t_ids where k = 'c_new')),
          'in_review:2', 'campaign in_review, FAQ bertambah');
select is((select array[subtotal, mgmt_fee, admin_fee, service_fee, tax, total] from finance.invoices
            where campaign_id = (select id from t_ids where k = 'c_new') and kind = 'campaign'),
          array[10000000, 1500000, 500000, 0, 220000, 12220000]::numeric[],
          '§5.2: budget Rp10 jt → mgmt 15% 1,5 jt + admin 5% 500 rb + PPN 11% atas fee = Rp12.220.000');
select ok((select number ~ '^INV-[0-9]{6}-[0-9]{6}$' and status = 'issued' and due_at > now() + interval '6 days'
             from finance.invoices where campaign_id = (select id from t_ids where k = 'c_new') and kind = 'campaign'),
          'nomor invoice INV-YYYYMM-000123, status issued, jatuh tempo 7 hari');
select is((select array_agg(p.username order by p.username) from ops.notifications n join market.profiles p on p.id = n.user_id
            where n.event = 'invoice.issued' and n.payload ->> 'campaign_id' = (select id from t_ids where k = 'c_new')::text),
          array['finance1', 'owner1'], 'invoice.issued ke brand_owner + brand_finance (bukan brand_manager)');
select is((select payload - 'invoice_id' - 'due_at' from ops.notifications where event = 'invoice.issued'
             and user_id = '22222222-0000-0000-0000-0000000000a1' and payload ->> 'campaign_id' = (select id from t_ids where k = 'c_new')::text),
          jsonb_build_object('invoice_number', (select number from finance.invoices where campaign_id = (select id from t_ids where k = 'c_new')),
                             'kind', 'campaign', 'total', 12220000.00, 'campaign_id', (select id from t_ids where k = 'c_new'),
                             'campaign_title', 'Film Baru Rilis', 'org_id', '44444444-0000-0000-0000-000000000001', 'org_name', 'Studio Satu'),
          'payload invoice.issued: invoice_number, total, campaign_title, org_name (template email & deep link /[org]/billing)');
select ok((select payload ?& array['invoice_id', 'due_at'] from ops.notifications where event = 'invoice.issued'
             and user_id = '22222222-0000-0000-0000-0000000000a1' and payload ->> 'campaign_id' = (select id from t_ids where k = 'c_new')::text),
          'payload invoice.issued memuat invoice_id + due_at');
select is((select array[mgmt_fee, admin_fee, tax, total] from finance.invoices where campaign_id = (select id from t_ids where k = 'c_org2')),
          array[200000, 100000, 33000, 2333000]::numeric[], 'fee rule org (10%) dipakai untuk campaign org itu');

-- Review campaign: approve hanya kalau invoice lunas
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_moderator}', 'aal2');
select throws_ok($$ select api.record_review('campaign', (select id from t_ids where k = 'c_new'), 'approve') $$, '42501', 'auth:forbidden',
                 'review campaign = admin_ops');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select throws_ok($$ select api.record_review('campaign', (select id from t_ids where k = 'c_new'), 'approve') $$, 'P0001', 'invoice_unpaid',
                 'approve campaign ditolak sebelum invoice lunas');
reset role;
update finance.invoices set status = 'paid', payment_channel = 'transfer', payment_ref = 'REF-CNEW', paid_amount = total, paid_at = now(),
       confirmed_by = '33333333-0000-0000-0000-0000000000ad'
 where campaign_id = (select id from t_ids where k = 'c_new') and kind = 'campaign';
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select lives_ok($$ select api.record_review('campaign', (select id from t_ids where k = 'c_new'), 'approve', null, 'Lolos') $$,
                'admin_ops approve setelah lunas');
select throws_ok($$ select api.record_review('campaign', (select id from t_ids where k = 'c_org2'), 'reject') $$, 'P0001', 'invalid:reason',
                 'reject campaign wajib alasan');
select lives_ok($$ select api.record_review('campaign', (select id from t_ids where k = 'c_org2'), 'reject', 'asset_rights',
                   'Hak aset belum jelas') $$, 'admin_ops reject campaign');
reset role;
select is((select status::text from market.campaigns where id = (select id from t_ids where k = 'c_new')), 'scheduled',
          'approve → scheduled (live oleh job lifecycle)');
select is((select count(*)::int from ops.notifications where event = 'campaign.approved'
             and payload ->> 'campaign_id' = (select id from t_ids where k = 'c_new')::text), 2,
          'campaign.approved ke brand_owner + brand_manager');
select ok((select bool_and(payload ->> 'campaign_title' = 'Film Baru Rilis' and payload ->> 'org_name' = 'Studio Satu'
                           and payload ? 'org_id' and payload ? 'campaign_id')
             from ops.notifications where event = 'campaign.approved'), 'payload campaign.approved: campaign_id/title + org_id/name');
select is((select count(*)::int from ops.audit_logs where action = 'review.campaign.approve'), 1, 'review campaign tercatat audit log');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2');
select lives_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_org2'), 'title', 'Toko Dua Promo Revisi')) $$,
                'campaign ditolak diperbaiki (kembali draft)');
select lives_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_org2')), true) $$,
                'campaign diajukan ulang');
reset role;
select is((select array_agg(status order by issued_at, status) from finance.invoices where campaign_id = (select id from t_ids where k = 'c_org2')),
          array['issued', 'void'], 'ajukan ulang: invoice lama yang belum lunas di-void, invoice baru terbit');
select is((select count(*)::int from ops.notifications where event = 'campaign.rejected' and payload ->> 'reason' = 'asset_rights'
             and user_id = '22222222-0000-0000-0000-0000000000a2'), 1, 'campaign.rejected + alasan ke brand');
-- Regresi review R6: invoice lunas saat in_review lalu ditolak → pool (akun ledger yang terisi) tidak boleh diganti.
update finance.invoices set status = 'paid', payment_channel = 'transfer', payment_ref = 'REF-ORG2', paid_amount = total, paid_at = now(),
       confirmed_by = '33333333-0000-0000-0000-0000000000ad'
 where campaign_id = (select id from t_ids where k = 'c_org2') and status = 'issued';
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select api.record_review('campaign', (select id from t_ids where k = 'c_org2'), 'reject', 'asset_rights', 'Masih belum jelas');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2');
select throws_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_org2'),
                    'pools', '[{"key":"q","reward_type_id":"77777777-0000-0000-0000-000000000001","total":2000000,"max_per_clip":10000}]'::jsonb,
                    'rules', '[{"kind":"flat_per_post","pool":"q","params":{"amount":25000}}]'::jsonb)) $$, 'P0001',
                 'pools_locked_after_payment', 'pool yang sudah dibayar tidak bisa diganti pool baru (total sama)');
select lives_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_org2'),
                   'pools', jsonb_build_array(jsonb_build_object('id', (select id from api.reward_pools
                      where campaign_id = (select id from t_ids where k = 'c_org2')), 'reward_type_id', '77777777-0000-0000-0000-000000000001',
                      'total', 2000000, 'max_per_clip', 20000)))) $$, 'pool yang sama (max_per_clip berubah) tetap boleh disimpan');
reset role;

-- Paket managed (J-A7): brand minta dibantu → admin menyusun (override fee) → invoice managed_service + managed.draft_ready
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
insert into t_ids (k, id) select 'c_managed', api.save_campaign('{"org_id":"44444444-0000-0000-0000-000000000001","title":"Bantu Kami",
  "type":"ugc","platforms":["instagram"],"service_mode":"managed","brief":"Brief mentah: promo toko, gaya santai."}');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select lives_ok($$ select api.save_campaign($j${"fee_rule":{"mgmt_fee_pct":12},"required_hashtags":["#Bantu"],
                   "pools":[{"key":"p","reward_type_id":"77777777-0000-0000-0000-000000000001","total":1000000,"max_per_clip":100000}],
                   "rules":[{"kind":"flat_per_post","pool":"p","params":{"amount":25000}}]}$j$::jsonb
                   || jsonb_build_object('id', (select id from t_ids where k = 'c_managed'), 'start_at', now() + interval '2 days',
                                         'submit_deadline', now() + interval '20 days'), true) $$,
                'admin_ops aal2 menyusun draft managed atas nama org lalu kirim ke brand');
reset role;
select is((select status::text from market.campaigns where id = (select id from t_ids where k = 'c_managed')), 'draft',
          'draft managed tetap draft sampai brand mengajukan');
select is((select array[subtotal, service_fee, tax, total] from finance.invoices
            where campaign_id = (select id from t_ids where k = 'c_managed') and kind = 'managed_service'),
          array[0, 2500000, 275000, 2775000]::numeric[], 'invoice managed_service = public.billing.managed_service_idr + PPN');
select is((select count(*)::int from ops.notifications where event = 'managed.draft_ready'
             and payload ->> 'campaign_id' = (select id from t_ids where k = 'c_managed')::text), 2,
          'managed.draft_ready ke brand_owner + brand_manager');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select lives_ok($$ select api.save_campaign(jsonb_build_object('id', (select id from t_ids where k = 'c_managed')), true) $$,
                'brand menyetujui ringkasan & mengajukan');
reset role;
select is((select array[mgmt_fee, admin_fee, tax, total] from finance.invoices
            where campaign_id = (select id from t_ids where k = 'c_managed') and kind = 'campaign'),
          array[120000, 50000, 18700, 1188700]::numeric[], 'override fee campaign (12%) mengalahkan fee org/global');
-- Regresi review R13: invoice budget lunas tapi invoice paket managed belum → approve ditolak.
update finance.invoices set status = 'paid', payment_channel = 'transfer', payment_ref = 'REF-MGD-C', paid_amount = total, paid_at = now(),
       confirmed_by = '33333333-0000-0000-0000-0000000000ad'
 where campaign_id = (select id from t_ids where k = 'c_managed') and kind = 'campaign';
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select throws_ok($$ select api.record_review('campaign', (select id from t_ids where k = 'c_managed'), 'approve') $$, 'P0001',
                 'invoice_unpaid', 'regresi R13: campaign managed tidak bisa tayang sebelum jasa managed lunas');
reset role;
update finance.invoices set status = 'issued', payment_channel = null, payment_ref = null, paid_amount = null, paid_at = null,
       confirmed_by = null
 where campaign_id = (select id from t_ids where k = 'c_managed') and kind = 'campaign';

-- Duplikat & template (F-B10)
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.duplicate_campaign('55555555-0000-0000-0000-000000000001', true) $$, '42501', 'auth:forbidden',
                 'clipper tidak bisa menduplikat');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
insert into t_ids (k, id) select 'c_dup', api.duplicate_campaign('55555555-0000-0000-0000-000000000001', true);
reset role;
select is((select array[status::text, is_template::text, (start_at is null)::text, (slug <> 'film-satu')::text] from market.campaigns
            where id = (select id from t_ids where k = 'c_dup')), array['draft', 'true', 'true', 'true'],
          'duplikat = draft (template), tanpa jadwal, slug baru');
select is((select array[count(distinct p.id), count(r.id), sum(p.allocated)]::numeric[] from finance.reward_pools p
            join market.rate_rules r on r.pool_id = p.id where p.campaign_id = (select id from t_ids where k = 'c_dup')),
          array[1, 1, 0]::numeric[], 'pool & rule aktif ikut disalin, allocated 0');

-- ---------- kontrol campaign (F-B06), undangan (F-B11), pin (REV-4) ----------
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1');
select throws_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'pause') $$, '42501', 'auth:forbidden',
                 'brand_finance tidak bisa menjeda');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select lives_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'pause') $$, 'pause live → paused');
select throws_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'pause') $$, 'P0001', 'invalid_state:paused',
                 'pause dua kali ditolak');
select lives_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'resume') $$, 'resume paused → live');
select throws_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'extend',
                    jsonb_build_object('submit_deadline', now() + interval '1 day')) $$, 'P0001', 'invalid:submit_deadline',
                 'perpanjang harus setelah deadline lama');
select lives_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'extend',
                   jsonb_build_object('submit_deadline', now() + interval '21 days')) $$, 'perpanjang deadline');
select throws_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'raise_rate',
                    '{"rule_id":"67676767-0000-0000-0000-000000000001","params":{"rate":1500}}') $$, 'P0001', 'invalid:rate_not_higher',
                 'raise_rate tidak bisa menurunkan rate');
select lives_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'raise_rate',
                   '{"rule_id":"67676767-0000-0000-0000-000000000001","params":{"rate":3000}}') $$, 'raise_rate Rp3.000');
reset role;
select is((select count(*)::int from market.rate_rules
            where lineage_id = '67676767-0000-0000-0000-000000000001' and effective_to is null), 1,
          'raise_rate: rule baru = versi rule lama (lineage_id)');
insert into market.rate_rules (id, campaign_id, kind, reward_type_id, pool_id, params)
select '67676767-0000-0000-0000-0000000000f7', pl.campaign_id, 'tiered_cpm', pl.reward_type_id, pl.id, '{"tiers":[{"from":0,"rate":1000}]}'
  from finance.reward_pools pl where pl.id = '66666666-0000-0000-0000-000000000001';
set local role authenticated;
select throws_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'raise_rate',
                    '{"rule_id":"67676767-0000-0000-0000-0000000000f7","params":{"tiers":[{"from":0,"to":10000,"rate":1001}]}}') $$,
                 'P0001', 'invalid:rate_not_higher', 'regresi R7: raise_rate tiered tidak bisa memasang plafon views (tier terbuka → to)');
reset role;
delete from market.rate_rules where id = '67676767-0000-0000-0000-0000000000f7';
set local role authenticated;
select throws_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'topup',
                    '{"pools":[{"pool_id":"66666666-0000-0000-0000-000000000002","amount":500000}]}') $$, 'P0001', 'invalid:pool',
                 'top-up hanya ke pool campaign itu');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1');
select lives_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'topup',
                   '{"pools":[{"pool_id":"66666666-0000-0000-0000-000000000001","amount":500000}]}') $$,
                'brand_finance top-up (invoice)');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select lives_ok($$ select api.control_campaign('55555555-0000-0000-0000-00000000000e', 'end_early') $$, 'akhiri lebih awal live → tracking');
select lives_ok($$ select api.control_campaign((select id from t_ids where k = 'c_managed'), 'end_early') $$,
                'batalkan campaign in_review → cancelled');
select throws_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'hapus') $$, 'P0001', 'invalid:action',
                 'aksi tidak dikenal ditolak');
reset role;
select is((select array[(select submit_deadline > now() + interval '20 days' from market.campaigns where id = '55555555-0000-0000-0000-000000000001'),
                        (select effective_to is not null from market.rate_rules where id = '67676767-0000-0000-0000-000000000001'),
                        (select effective_to is null and params ->> 'rate' = '3000' from market.rate_rules
                          where campaign_id = '55555555-0000-0000-0000-000000000001'
                            and lineage_id = '67676767-0000-0000-0000-000000000001')]),
          array[true, true, true], 'extend tersimpan; raise_rate = rule lama ditutup + rule baru');
select is((select array[subtotal, mgmt_fee, admin_fee, tax, total] from finance.invoices
            where campaign_id = '55555555-0000-0000-0000-000000000001' and kind = 'topup'),
          array[500000, 75000, 25000, 11000, 611000]::numeric[], 'invoice top-up dengan fee + PPN');
select is((select pool_topups from finance.invoices where campaign_id = '55555555-0000-0000-0000-000000000001' and kind = 'topup'),
          '[{"amount": 500000, "pool_id": "66666666-0000-0000-0000-000000000001"}]'::jsonb,
          'pool_topups untuk confirm_invoice_payment; pool belum bertambah sebelum lunas');
select is((select total from finance.reward_pools where id = '66666666-0000-0000-0000-000000000001'), 1000000::numeric,
          'total pool tetap sampai invoice top-up lunas');
select is((select array[(select status::text from market.campaigns where id = '55555555-0000-0000-0000-00000000000e'),
                        (select status::text from market.claims where id = '88888888-0000-0000-0000-00000000000e'),
                        (select status::text from market.campaigns where id = (select id from t_ids where k = 'c_managed')),
                        (select string_agg(status, ',' order by kind) from finance.invoices where campaign_id = (select id from t_ids where k = 'c_managed'))]),
          array['tracking', 'released', 'cancelled', 'void,void'],
          'end_early: claim terbuka dilepas; batal sebelum tayang → invoice belum lunas di-void');

set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.invite_to_campaign('55555555-0000-0000-0000-000000000008', array['andi']) $$, '42501', 'auth:forbidden',
                 'clipper tidak bisa mengundang');
select is((select count(*)::int from api.campaigns where id = '55555555-0000-0000-0000-000000000008'), 0,
          'campaign invite belum terlihat sebelum diundang');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select is(api.invite_to_campaign('55555555-0000-0000-0000-000000000008', array['@Andi', 'tidakada', 'andi']), 1,
          'undangan: username dinormalisasi, yang tidak ada diabaikan');
select is(api.invite_to_campaign('55555555-0000-0000-0000-000000000008', array['andi']), 0, 'undangan ulang tidak dihitung');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select is((select count(*)::int from api.campaigns where id = '55555555-0000-0000-0000-000000000008'), 1,
          'campaign privat terlihat setelah diundang');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select throws_ok($$ select api.buy_pin('55555555-0000-0000-0000-000000000001', 0) $$, 'P0001', 'invalid:days', 'durasi pin 1–90 hari');
select throws_ok($$ select api.buy_pin('55555555-0000-0000-0000-0000000000d1', 7) $$, 'P0001', 'invalid_state:draft',
                 'draft tidak bisa di-pin');
insert into t_ids (k, id) select 'inv_pin', api.buy_pin('55555555-0000-0000-0000-000000000001', 10);
reset role;
select is((select count(*)::int from ops.notifications where event = 'campaign.invited' and user_id = '11111111-0000-0000-0000-00000000000a'), 1,
          'notifikasi campaign.invited sekali');
select is((select payload from ops.notifications where event = 'campaign.invited' and user_id = '11111111-0000-0000-0000-00000000000a'),
          '{"campaign_id":"55555555-0000-0000-0000-000000000008","campaign_title":"Khusus Undangan","campaign_slug":"undangan",
            "org_id":"44444444-0000-0000-0000-000000000001","org_name":"Studio Satu"}'::jsonb, 'payload campaign.invited');
select is((select array[subtotal, service_fee, tax, total] from finance.invoices where id = (select id from t_ids where k = 'inv_pin')),
          array[0, 1000000, 110000, 1110000]::numeric[], 'pin 10 hari = 2 minggu × Rp500.000 + PPN');
select ok((select kind = 'pinned' and pin_until between now() + interval '10 days' - interval '1 minute' and now() + interval '10 days'
             from finance.invoices where id = (select id from t_ids where k = 'inv_pin')), 'invoice pinned membawa pin_until');
select is((select pinned_until from market.campaigns where id = '55555555-0000-0000-0000-000000000001'), null,
          'pinned_until baru diset saat invoice lunas');
-- Regresi review R13: invoice pin dibayar 3 hari setelah terbit → tetap dapat 10 hari penuh sejak lunas.
update finance.invoices set pin_until = now() + interval '7 days' where id = (select id from t_ids where k = 'inv_pin');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', array['admin_finance'], 'aal2');
select api.confirm_invoice_payment((select id from t_ids where k = 'inv_pin'),
                                   (select total from api.invoices where id = (select id from t_ids where k = 'inv_pin')), now(), 'REF-PIN-1', 'transfer');
reset role;
select is((select pinned_until from market.campaigns where id = '55555555-0000-0000-0000-000000000001'), now() + interval '10 days',
          'regresi R13: durasi pin dihitung sejak lunas (hari yang dibeli utuh)');
select is((select pin_until from finance.invoices where id = (select id from t_ids where k = 'inv_pin')), now() + interval '10 days',
          'invoice pin mencatat periode sebenarnya');
update market.campaigns set pinned_until = null where id = '55555555-0000-0000-0000-000000000001';
-- Regresi review R14: invoice pin terbit sebelum pin_days ada (7 hari, 10 hari lalu), dibayar sekarang → tetap 7 hari sejak lunas.
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
insert into t_ids (k, id) select 'inv_pin_old', api.buy_pin('55555555-0000-0000-0000-000000000001', 7);
reset role;
update finance.invoices set pin_days = null, issued_at = now() - interval '10 days', pin_until = now() - interval '3 days'
 where id = (select id from t_ids where k = 'inv_pin_old');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', array['admin_finance'], 'aal2');
select api.confirm_invoice_payment((select id from t_ids where k = 'inv_pin_old'),
                                   (select total from api.invoices where id = (select id from t_ids where k = 'inv_pin_old')), now(), 'REF-PIN-OLD', 'transfer');
reset role;
select is((select pinned_until from market.campaigns where id = '55555555-0000-0000-0000-000000000001'), now() + interval '7 days',
          'regresi R14: invoice pin lama dibayar telat tetap dapat durasinya sejak lunas');
update market.campaigns set pinned_until = null where id = '55555555-0000-0000-0000-000000000001';
-- Regresi review R15: invoice pin lama yang memperpanjang pin berjalan (sisa 7 hari + beli 7 hari) → tambah 7 hari, bukan 14.
update market.campaigns set pinned_until = now() + interval '7 days' where id = '55555555-0000-0000-0000-000000000001';
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
insert into t_ids (k, id) select 'inv_pin_ext', api.buy_pin('55555555-0000-0000-0000-000000000001', 7);
reset role;
update finance.invoices set pin_days = null where id = (select id from t_ids where k = 'inv_pin_ext');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', array['admin_finance'], 'aal2');
select api.confirm_invoice_payment((select id from t_ids where k = 'inv_pin_ext'),
                                   (select total from api.invoices where id = (select id from t_ids where k = 'inv_pin_ext')), now(), 'REF-PIN-EXT', 'transfer');
reset role;
select is((select pinned_until from market.campaigns where id = '55555555-0000-0000-0000-000000000001'), now() + interval '14 days',
          'regresi R15: perpanjangan pin lama = minggu yang dibayar, sisa pin tidak dihitung dua kali');
update market.campaigns set pinned_until = null where id = '55555555-0000-0000-0000-000000000001';

-- ---------- daftar campaign (F-C03): visibilitas = RLS, CTA 6 state per user, keyset ----------
set local role anon;
select pg_temp.anon();
select is(array(select id from api.list_campaigns('{"status":"all","limit":50}') order by id),
          array(select id from api.campaigns where status in ('live', 'paused', 'tracking', 'exhausted', 'settling', 'settled')
                and not is_template order by id), 'anon: baris list_campaigns = RLS api.campaigns');
select is((select array_agg(slug order by slug collate "C") from api.list_campaigns('{}')),
          array['budget-habis', 'deadline-lewat', 'dijeda', 'film-satu', 'follower-tinggi', 'kyc-wajib', 'maks-klip', 'review-brand',
                'slot-penuh', 'trust-limapuluh', 'umur-akun'],
          'anon: default live + paused, hanya visibility public (tanpa invite/level)');
select is((select count(*)::int from api.list_campaigns('{"status":"all","limit":50}') where cta_state is not null or cta_reason is not null), 0,
          'anon: cta_state NULL');
select is((select row(brand_name, brand_verified)::text from api.list_campaigns('{}') where slug = 'film-satu'), '("Studio Satu",t)',
          'anon: kartu campaign membawa nama brand + status verified');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000001') $$, '42501', null, 'anon tidak bisa claim');
select throws_ok($$ select api.campaign_detail('55555555-0000-0000-0000-000000000001') $$, '42501', null,
                 'anon tidak bisa memanggil campaign_detail');
reset role;
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select is(array(select id from api.list_campaigns('{"status":"all","limit":50}') order by id),
          array(select id from api.campaigns where status in ('live', 'paused', 'tracking', 'exhausted', 'settling', 'settled')
                and not is_template order by id), 'Andi: baris list_campaigns = RLS api.campaigns (undangan ikut, level 70 tidak)');
select is((select array_agg(slug || '=' || cta_state || coalesce(':' || cta_reason, '') order by slug collate "C")
             from api.list_campaigns('{"status":"all","limit":50}')),
          array['budget-habis=budget_exhausted', 'deadline-lewat=deadline_passed', 'diakhiri=deadline_passed',
                'dijeda=not_eligible:campaign_not_live', 'film-satu=can_claim', 'follower-tinggi=not_eligible:min_followers',
                'kyc-wajib=not_eligible:kyc_required', 'maks-klip=not_eligible:max_clips', 'review-brand=can_claim',
                'slot-penuh=slots_full', 'trust-limapuluh=can_claim', 'umur-akun=can_claim', 'undangan=can_claim'],
          'Andi: CTA per campaign (bisa claim, slot penuh, budget habis, deadline lewat, tidak eligible + alasan)');
select is((select array[est_remaining_views ->> 'tiktok', remaining_idr::text, budget_idr::text, is_new::text, (cover_path like '%/cover.webp')::text,
                        is_pinned::text]
             from api.list_campaigns('{"q":"film satu"}') where slug = 'film-satu'),
          array['500000', '1000000', '1000000', 'true', 'true', 'false'],
          'card: ± sisa views (Rp1 jt ÷ Rp2.000 × 1.000), sisa budget, badge Baru, cover');
select is((select array_agg(slug) from api.list_campaigns('{"q":"habis"}')), array['budget-habis'], 'cari judul');
select is((select count(*)::int from api.list_campaigns('{"platform":"instagram","status":"all"}')), 0, 'filter platform');
select is((select count(*)::int from api.list_campaigns('{"category":"music","status":"all"}')), 0, 'filter kategori');
select is((select array_agg(slug) from api.list_campaigns('{"slug":"film-satu","status":"all"}')), array['film-satu'], 'filter slug (halaman publik)');
select is((select slug from api.list_campaigns('{"status":"all","sort":"deadline","limit":1}')), 'deadline-lewat', 'sort deadline terdekat dulu');
select throws_ok($$ select * from api.list_campaigns('{"sort":"acak"}') $$, 'P0001', 'invalid:sort', 'sort tidak dikenal ditolak');
select throws_ok($$ select * from api.list_campaigns('{}', 'bukan-cursor') $$, 'P0001', 'invalid:cursor', 'cursor rusak ditolak');
insert into t_ids (k, tok) select 'page1', (array_agg(next_cursor))[5] from api.list_campaigns('{"status":"all","sort":"budget","limit":5}');
select is(array(select id from api.list_campaigns('{"status":"all","sort":"budget","limit":5}'))
          || array(select id from api.list_campaigns('{"status":"all","sort":"budget","limit":5}', (select tok from t_ids where k = 'page1'))),
          (array(select id from api.list_campaigns('{"status":"all","sort":"budget","limit":50}')))[1:10],
          'keyset: halaman 2 menyambung halaman 1 tanpa duplikat');

-- CTA user lain (alasan tidak eligible)
select pg_temp.jwt('11111111-0000-0000-0000-00000000000b');
select is(array(select id from api.list_campaigns('{"status":"all","limit":50}') order by id),
          array(select id from api.campaigns where status in ('live', 'paused', 'tracking', 'exhausted', 'settling', 'settled')
                and not is_template order by id), 'Budi: baris list_campaigns = RLS api.campaigns');
select is((select array_agg(slug || '=' || cta_state || coalesce(':' || cta_reason, '') order by slug collate "C")
             from api.list_campaigns('{"status":"all","limit":50}') where slug in ('film-satu', 'slot-penuh', 'trust-limapuluh', 'umur-akun')),
          array['film-satu=not_eligible:min_followers', 'slot-penuh=claimed_not_submitted', 'trust-limapuluh=not_eligible:min_trust_score',
                'umur-akun=not_eligible:min_account_age'],
          'Budi: sudah claim belum submit, follower / Trust Score / umur akun kurang');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000e');
select is(array(select id from api.list_campaigns('{"status":"all","limit":50}') order by id),
          array(select id from api.campaigns where status in ('live', 'paused', 'tracking', 'exhausted', 'settling', 'settled')
                and not is_template order by id), 'Eko (Trust 70): baris list_campaigns = RLS api.campaigns (level 70 ikut)');
select is((select cta_state from api.list_campaigns('{"status":"all","limit":50}') where slug = 'level-tujuh'), 'can_claim',
          'Eko bisa claim campaign level 70');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000c');
select is((select cta_reason from api.list_campaigns('{}') where slug = 'film-satu'), 'need_social_account:tiktok',
          'Citra: belum punya akun TikTok terverifikasi');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000d');
select is((select cta_reason from api.list_campaigns('{}') where slug = 'film-satu'), 'profile_inactive', 'Dodi disuspend');
select pg_temp.jwt('11111111-0000-0000-0000-0000000000f9');
select is((select cta_reason from api.list_campaigns('{}') where slug = 'film-satu'), 'profile_missing', 'belum ensure_profile');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select is(array(select id from api.list_campaigns('{"status":"all","limit":50}') order by id),
          array(select id from api.campaigns where status in ('live', 'paused', 'tracking', 'exhausted', 'settling', 'settled')
                and not is_template order by id), 'manager org1: baris list_campaigns = RLS api.campaigns');
select is((select cta_reason from api.list_campaigns('{}') where slug = 'film-satu'), 'own_org', 'anggota org pemilik tidak eligible');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select is(array(select id from api.list_campaigns('{"status":"all","limit":50}') order by id),
          array(select id from api.campaigns where status in ('live', 'paused', 'tracking', 'exhausted', 'settling', 'settled')
                and not is_template order by id), 'admin aal2: baris list_campaigns = RLS api.campaigns');
select is((select cta_reason from api.list_campaigns('{"status":"all","limit":50}') where slug = 'undangan'), 'not_invited',
          'campaign invite tanpa undangan → not_invited');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a', p_extra => '{"iss":"https://evil.example/auth/v1"}');
select throws_ok($$ select * from api.list_campaigns('{}') $$, '42501', 'auth:no_session', 'JWT iss lain ditolak');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000001') $$, '42501', 'auth:no_session',
                 'claim dengan iss lain ditolak');

-- ---------- claim (F-C05) ----------
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
insert into t_ids (k, id) select 'claim_a', (api.claim_campaign('55555555-0000-0000-0000-000000000001')).id;
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000001') $$, 'P0001', 'already_claimed',
                 'claim kedua ditolak selama claim pertama terbuka');
select is((select cta_state from api.list_campaigns('{}') where slug = 'film-satu'), 'claimed_not_submitted',
          'CTA berubah jadi sudah claim belum submit');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000002') $$, 'P0001', 'slots_full', 'kuota clipper penuh');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000003') $$, 'P0001', 'budget_exhausted', 'budget habis');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000004') $$, 'P0001', 'deadline_passed', 'deadline lewat');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000005') $$, 'P0001', 'not_eligible:min_followers',
                 'follower kurang');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000006') $$, 'P0001', 'not_eligible:max_clips',
                 'maks klip per clipper');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000009') $$, 'P0001', 'not_eligible:kyc_required',
                 'KYC disyaratkan');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-00000000000c') $$, 'P0001', 'not_eligible:campaign_not_live',
                 'campaign dijeda');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-00000000000d') $$, 'P0002', 'not_found:campaign',
                 'campaign level di atas Trust Score tidak terlihat');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-0000000000d1') $$, 'P0002', 'not_found:campaign', 'draft tidak terlihat');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a', p_extra => '{"kyc":"approved"}');
select lives_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000009') $$, 'claim KYC approved (claim JWT kyc)');
reset role;
insert into market.claims (id, campaign_id, user_id, expires_at, created_at) values
  ('88888888-0000-0000-0000-0000000000aa', '55555555-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-00000000000a',
   now() - interval '2 hours', now() - interval '50 hours');
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select lives_ok($$ select api.claim_campaign('55555555-0000-0000-0000-00000000000a') $$,
                'claim lama yang lewat waktu (belum diproses job) tidak menghalangi claim baru');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000c');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000001') $$, 'P0001', 'not_eligible:need_social_account:tiktok',
                 'belum hubungkan akun platform campaign');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000d');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000001') $$, 'P0001', 'not_eligible:profile_inactive',
                 'profil disuspend tidak bisa claim');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000001') $$, 'P0001', 'not_eligible:own_org',
                 'anggota org pemilik tidak bisa claim');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000e1');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000001') $$, 'P0001', 'not_eligible:need_social_account:tiktok',
                 'agency yang tautannya dicabut bukan lagi anggota org (lanjut ke cek akun)');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000b');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-00000000000a') $$, 'P0001', 'not_eligible:min_account_age',
                 'umur akun sosmed kurang');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-00000000000b') $$, 'P0001', 'not_eligible:min_trust_score',
                 'Trust Score kurang');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000e');
select throws_ok($$ select api.claim_campaign('55555555-0000-0000-0000-000000000002') $$, 'P0001', 'slots_full',
                 'clipper lain juga kena slot penuh');
reset role;
select ok((select status = 'open' and expires_at = now() + interval '48 hours' and user_id = '11111111-0000-0000-0000-00000000000a'
             from market.claims where id = (select id from t_ids where k = 'claim_a')),
          'claim terbuka, kedaluwarsa public.market.claim_hours (48 jam)');
select is((select status::text from market.claims where id = '88888888-0000-0000-0000-0000000000aa'), 'expired',
          'claim lama ditandai expired');

-- ---------- detail campaign (F-C04) ----------
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
insert into t_json (k, j) select 'detail_a', api.campaign_detail('55555555-0000-0000-0000-000000000001');
select is((select j -> 'brand' from t_json where k = 'detail_a'), '{"name": "Studio Satu", "verified": true}'::jsonb,
          'detail campaign membawa nama brand untuk clipper');
select is((select j ->> 'clipper_fee_pct' from t_json where k = 'detail_a')::numeric,
          0::numeric, 'detail campaign membawa potongan clipper yang berlaku (fixture 0%; app menampilkan bila > 0)');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
insert into t_json (k, j) select 'detail_o', api.campaign_detail('55555555-0000-0000-0000-000000000001');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000b');
select throws_ok($$ select api.campaign_detail('55555555-0000-0000-0000-00000000000d') $$, 'P0002', 'not_found:campaign',
                 'detail campaign yang tidak terlihat ditolak');
reset role;
select is((select array[j ->> 'cta_state', j #>> '{my,claim,status}', jsonb_array_length(j -> 'assets')::text,
                        j #>> '{assets,0,bucket}', j #>> '{pools,0,est_remaining_views,tiktok}', j #>> '{campaign,slug}']
             from t_json where k = 'detail_a'),
          array['claimed_not_submitted', 'open', '2', 'campaign-covers', '500000', 'film-satu'],
          'detail clipper: CTA, claim sendiri, aset tanpa berkas internal, sisa views per pool');
select is((select jsonb_array_length(j -> 'assets') from t_json where k = 'detail_o'), 3, 'detail anggota org: berkas internal ikut');

-- ---------- review submisi (F-A05, F-B07), banding (F-C07), auto-approve 72 jam ----------
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.record_review('submission', 'aaaaaaaa-0000-0000-0000-000000000071', 'approve') $$, '42501', 'auth:forbidden',
                 'clipper tidak bisa mereview');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2');
select throws_ok($$ select api.record_review('submission', 'aaaaaaaa-0000-0000-0000-000000000071', 'approve') $$, '42501', 'auth:forbidden',
                 'org lain tidak bisa mereview');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select lives_ok($$ select api.record_review('submission', 'aaaaaaaa-0000-0000-0000-000000000071', 'approve') $$,
                'brand_owner approve submisi campaign review brand');
select throws_ok($$ select api.record_review('submission', 'aaaaaaaa-0000-0000-0000-000000000075', 'approve') $$, '42501', 'auth:forbidden',
                 'brand tidak bisa mereview campaign review manual (admin)');
select throws_ok($$ select api.record_review('submission', 'aaaaaaaa-0000-0000-0000-000000000072', 'reject') $$, 'P0001', 'invalid:reason',
                 'reject wajib alasan standar');
select lives_ok($$ select api.record_review('submission', 'aaaaaaaa-0000-0000-0000-000000000072', 'reject', 'missing_hashtag',
                   'Hashtag #mplid tidak ada') $$, 'brand_owner reject + alasan');
select throws_ok($$ select api.record_review('submission', 'aaaaaaaa-0000-0000-0000-000000000071', 'approve') $$, '42501', 'auth:forbidden',
                 'brand hanya memutus submisi yang masih in_review');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_moderator}', 'aal1');
select throws_ok($$ select api.record_review('submission', 'aaaaaaaa-0000-0000-0000-000000000075', 'approve') $$, '42501', 'auth:forbidden',
                 'moderator tanpa aal2 ditolak');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_moderator}', 'aal2');
select lives_ok($$ select api.record_review('submission', 'aaaaaaaa-0000-0000-0000-000000000075', 'approve') $$,
                'admin_moderator aal2 approve submisi review manual');
select throws_ok($$ select api.record_review('submission', 'aaaaaaaa-0000-0000-0000-000000000071', 'approve') $$, 'P0001',
                 'invalid_state:tracking', 'submisi yang sudah tracking tidak bisa di-approve lagi');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.appeal_submission('aaaaaaaa-0000-0000-0000-000000000072', 'tolong cek') $$, 'P0002', 'not_found:submission',
                 'hanya pemilik yang bisa banding');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000e');
select throws_ok($$ select api.appeal_submission('aaaaaaaa-0000-0000-0000-000000000072', ' ') $$, 'P0001', 'invalid:message',
                 'banding wajib alasan');
select throws_ok($$ select api.appeal_submission('aaaaaaaa-0000-0000-0000-000000000075', 'kenapa') $$, 'P0001', 'invalid_state:tracking',
                 'banding hanya dari rejected');
select lives_ok($$ select api.appeal_submission('aaaaaaaa-0000-0000-0000-000000000072', 'Hashtag ada di komentar pertama') $$,
                'pemilik banding sekali');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000b');
select throws_ok($$ select api.appeal_submission('aaaaaaaa-0000-0000-0000-000000000076', 'sekali lagi') $$, 'P0001', 'appeal_used',
                 'banding kedua ditolak (unique index)');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select throws_ok($$ select api.record_review('submission', 'aaaaaaaa-0000-0000-0000-000000000072', 'uphold', 'missing_hashtag') $$, '42501',
                 'auth:forbidden', 'banding diputus admin, bukan brand');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_moderator}', 'aal2');
select lives_ok($$ select api.record_review('submission', 'aaaaaaaa-0000-0000-0000-000000000072', 'reject', 'missing_hashtag',
                   'Banding ditolak') $$, 'admin menolak banding (uphold)');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000e');
select throws_ok($$ select api.appeal_submission('aaaaaaaa-0000-0000-0000-000000000072', 'lagi') $$, 'P0001', 'invalid_state:rejected_final',
                 'tidak ada banding setelah rejected_final');
reset role;
select is((select array[status::text, (next_poll_at = now())::text] from tracking.submissions where id = 'aaaaaaaa-0000-0000-0000-000000000071'),
          array['tracking', 'true'], 'approve → tracking + next_poll_at = now() (diambil job track-due)');
select is((select array_agg(decision order by id) from trust.review_decisions where target_id = 'aaaaaaaa-0000-0000-0000-000000000072'),
          array['reject', 'appeal', 'uphold'], 'riwayat keputusan: reject → appeal → uphold');
select is((select status::text from tracking.submissions where id = 'aaaaaaaa-0000-0000-0000-000000000072'), 'rejected_final',
          'banding ditolak → rejected_final');
select is((select array_agg(event || ':' || coalesce(payload ->> 'final', '') order by id) from ops.notifications
            where user_id = '11111111-0000-0000-0000-00000000000e' and event like 'submission.%'),
          array['submission.rejected:false', 'submission.approved:false', 'submission.rejected:true'],
          'notifikasi submisi approved/rejected ke clipper');
select is((select payload - 'submission_id' from ops.notifications where user_id = '11111111-0000-0000-0000-00000000000e'
             and event = 'submission.rejected' and payload ->> 'final' = 'false'),
          '{"campaign_id":"55555555-0000-0000-0000-000000000007","campaign_title":"Review Brand","url":"https://tiktok.com/v/72",
            "reason":"missing_hashtag","message":"Hashtag #mplid tidak ada","final":false}'::jsonb,
          'payload submission.rejected: campaign_title, url, reason, message');
select is((select array_agg(reason || ':' || delta order by id) from trust.score_events where user_id = '11111111-0000-0000-0000-00000000000e'),
          array['submission_rejected:-2', 'submission_approved:1', 'appeal_failed:-3'], 'Trust Score: delta dari trust.score_deltas');
select is((select count(*)::int from ops.audit_logs where action like 'review.submission.%'), 2, 'keputusan admin tercatat audit log');
select is(trust.auto_approve_overdue(), 1, 'auto-approve: hanya submisi review brand yang menunggu > 72 jam');
select is((select array[s.status::text, d.decision, coalesce(d.actor_id::text, 'null'), d.note] from tracking.submissions s
             join trust.review_decisions d on d.target_id = s.id where s.id = 'aaaaaaaa-0000-0000-0000-000000000073'),
          array['tracking', 'auto_approve', 'null', 'auto'], 'auto_approve tanpa pelaku, catatan auto');
select is((select status::text from tracking.submissions where id = 'aaaaaaaa-0000-0000-0000-000000000077'), 'in_review',
          'submisi review manual tidak di-auto-approve');
insert into market.referrals (referred_id, referrer_id, code) values
  ('11111111-0000-0000-0000-00000000000b', '11111111-0000-0000-0000-00000000000a', 'ANDI');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_moderator}', 'aal2');
select lives_ok($$ select api.record_review('kyc', '11111111-0000-0000-0000-00000000000b', 'approve') $$,
                'keputusan KYC dicatat core (tanpa PII)');
reset role;
select ok((select qualified_at is not null and bonus_until > now() + interval '89 days' from market.referrals
            where referred_id = '11111111-0000-0000-0000-00000000000b'),
          'regresi R8: referral berlaku sejak KYC disetujui (earning sebelum withdraw pertama ikut bonus)');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_moderator}', 'aal2');
select throws_ok($$ select api.record_review('org', (select id from t_ids where k = 'org_new'), 'approve') $$, '42501', 'auth:forbidden',
                 'verifikasi org = admin_ops');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select lives_ok($$ select api.record_review('org', (select id from t_ids where k = 'org_new'), 'approve') $$,
                'record_review target org = manage_org verify');
reset role;
select is((select count(*)::int from ops.notifications where event = 'kyc.approved' and user_id = '11111111-0000-0000-0000-00000000000b'), 1,
          'notifikasi KYC disetujui');
select is((select status::text from market.organizations where id = (select id from t_ids where k = 'org_new')), 'verified',
          'org diverifikasi lewat record_review');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select throws_ok($$ select api.manage_org((select id from t_ids where k = 'org_new'), 'suspend') $$, 'P0001', 'invalid:reason',
                 'suspend org wajib alasan');
select lives_ok($$ select api.manage_org((select id from t_ids where k = 'org_new'), 'suspend', '{"reason":"chargeback"}') $$,
                'admin_ops suspend org');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2');
select throws_ok($$ select api.save_campaign(jsonb_build_object('org_id', (select id from t_ids where k = 'org_new'), 'title', 'Setelah Suspend',
                    'type', 'ugc', 'platforms', '["tiktok"]'::jsonb)) $$, 'P0001', 'org_suspended', 'org disuspend tidak bisa membuat campaign');
reset role;
select is((select count(*)::int from ops.notifications where event = 'org.suspended' and user_id = '22222222-0000-0000-0000-0000000000a2'), 1,
          'notifikasi org.suspended');

-- ---------- dashboard brand (F-B05, F-B08) & profil clipper (F-C12) ----------
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.campaign_stats('55555555-0000-0000-0000-000000000006') $$, '42501', 'auth:forbidden',
                 'dashboard campaign hanya untuk anggota org');
insert into t_json (k, j) select 'my_a', api.my_stats();
reset role;
-- Fee yang ditagih (C18-4): invoice campaign lunas, fee 15% + 5% dari budget Rp1 jt → Rp200.000, diprorata ke spend.
insert into finance.invoices (number, org_id, campaign_id, kind, subtotal, mgmt_fee, admin_fee, service_fee, tax, total, status,
                              payment_channel, payment_ref, paid_amount, paid_at, confirmed_by)
select 'INV-L6', c.org_id, c.id, 'campaign', 1000000, 150000, 50000, 0, 0, 1200000, 'paid', 'transfer', 'REF-L6', 1200000, now(),
       '33333333-0000-0000-0000-0000000000ad'
  from market.campaigns c where c.id = '55555555-0000-0000-0000-000000000006';
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1');
insert into t_json (k, j) select 'stats_l6', api.campaign_stats('55555555-0000-0000-0000-000000000006');
reset role;
select ok((select j @> market.campaign_report('55555555-0000-0000-0000-000000000006') from t_json where k = 'stats_l6'),
          'campaign_stats memuat angka yang sama dengan laporan read-only (satu sumber hitung)');
select is((select array[j ->> 'views_valid', j ->> 'spent_idr', j ->> 'ecpm_idr', j ->> 'utilization_pct', j #>> '{by_platform,tiktok}',
                        j #>> '{daily,0,views}', j #>> '{daily,1,views}', j #>> '{pools,0,remaining}']
             from t_json where k = 'stats_l6'),
          array['25000', '50000', '2400', '5', '25000', '10000', '15000', '950000'],
          'dashboard: views valid, spend, eCPM (G-8: total bayar brand = spend + fee yang ditagih, prorata), utilisasi, split platform, kurva harian, sisa pool');
reset role;
update finance.fee_rules set mgmt_fee_pct = 30 where scope = 'global';
select is((select market.campaign_report('55555555-0000-0000-0000-000000000006') ->> 'ecpm_idr'), '2400',
          'C18-4: fee rule berubah belakangan tidak mengubah eCPM campaign yang sudah ditagih');
update finance.fee_rules set mgmt_fee_pct = 15 where scope = 'global';
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1');
select is((select (j #>> '{projection,projected_utilization_pct}')::numeric < 50 from t_json where k = 'stats_l6'), true,
          'proyeksi pemakaian budget < 50% (dasar alert & saran)');
select is((select array[j ->> 'total_views', j ->> 'approved', j ->> 'approval_rate', j ->> 'trust_score', j #>> '{earnings,0,pending}',
                        j #>> '{earnings,0,code}']
             from t_json where k = 'my_a'),
          array['25000', '2', '100.0', '60', '50000', 'IDR'], 'my_stats: views, approval rate, earning per reward type, Trust Score');

-- ---------- config admin (F-A04, F-A09, F-A11) ----------
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select lives_ok($$ select api.update_config('public.home.banners', '[{"img":"banner/1.webp","href":"/campaigns"}]') $$,
                'admin_ops mengatur banner beranda');
select throws_ok($$ select api.update_config('public.billing.tax_pct', '12') $$, '42501', 'auth:forbidden', 'tarif/flag/finance hanya admin_super');
select throws_ok($$ select api.update_config('fee_rules.global', '{"mgmt_fee_pct":14}') $$, '42501', 'auth:forbidden',
                 'fee global hanya admin_super');
select lives_ok($$ select api.update_config('categories.upsert', '{"id":"podcast","name_id":"Podcast","name_en":"Podcast","sort":6}') $$,
                'admin_ops menambah kategori');
select lives_ok($$ select api.update_config('campaign.pin', jsonb_build_object('campaign_id', '55555555-0000-0000-0000-000000000005',
                   'rank', 1, 'until', now() + interval '7 days')) $$, 'admin_ops mengatur pinned');
select lives_ok($$ select api.update_config('fee_rules.campaign', '{"campaign_id":"55555555-0000-0000-0000-000000000001","mgmt_fee_pct":12}') $$,
                'admin_ops override fee per campaign');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_super}', 'aal1');
select throws_ok($$ select api.update_config('public.billing.tax_pct', '12') $$, '42501', 'auth:forbidden', 'admin_super tetap butuh aal2');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_super}', 'aal2');
select throws_ok($$ select api.update_config('public.billing.tax_pct', '"12"') $$, 'P0001', 'invalid:value_type', 'tipe nilai config dijaga');
select throws_ok($$ select api.update_config('public.tidak.ada', '1') $$, 'P0001', 'invalid:config_key', 'kunci config tak dikenal ditolak');
select throws_ok($$ select api.update_config('auth.identity_issuer', '"https://lain.example/auth/v1"') $$, 'P0001', 'config_key_locked',
                 'issuer identity tidak bisa diubah dari admin');
select lives_ok($$ select api.update_config('fee_rules.global', '{"mgmt_fee_pct":14}') $$, 'admin_super mengubah fee global');
select lives_ok($$ select api.update_config('public.billing.tax_pct', '12') $$, 'admin_super mengubah tarif pajak');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000b1');
select lives_ok($$ select api.control_campaign('55555555-0000-0000-0000-000000000001', 'topup',
                   '{"pools":[{"pool_id":"66666666-0000-0000-0000-000000000001","amount":100000}]}') $$, 'top-up setelah config berubah');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select is((select array[slug, is_pinned::text, pinned_rank::text] from api.list_campaigns('{}') limit 1),
          array['follower-tinggi', 'true', '1'], 'campaign pinned tampil paling atas');
reset role;
select is((select value from ops.settings where key = 'public.home.banners'), '[{"img":"banner/1.webp","href":"/campaigns"}]'::jsonb,
          'banner tersimpan');
select is((select array[before::text, after ->> 0] from ops.audit_logs where target = 'settings:public.home.banners'),
          array['[]', '{"img": "banner/1.webp", "href": "/campaigns"}'], 'audit log menyimpan nilai sebelum & sesudah');
select is((select name_en || ':' || sort from market.categories where id = 'podcast'), 'Podcast:6', 'kategori tersimpan');
select is((select mgmt_fee_pct from finance.fee_rules where scope = 'global'), 14.00::numeric, 'fee global berubah');
select is((select array[subtotal, mgmt_fee, admin_fee, tax, total] from finance.invoices
            where campaign_id = '55555555-0000-0000-0000-000000000001' and kind = 'topup' and subtotal = 100000),
          array[100000, 12000, 5000, 2040, 119040]::numeric[], 'invoice baru memakai override fee campaign (12%) + pajak config (12%)');
select is((select array_agg(action order by id) from ops.audit_logs where action like 'config.%'),
          array['config.update', 'config.category', 'config.pin', 'config.fee_rule', 'config.fee_rule', 'config.update'],
          'setiap perubahan config tercatat');

-- ---------- job:budget-alerts (F-B08) ----------
update finance.reward_pools set allocated = 550000 where id = '66666666-0000-0000-0000-000000000001';
select ok(market.run_budget_alerts() > 0, 'job budget-alerts mengirim notifikasi');
select is((select array_agg(payload ->> 'pct' order by id) from ops.notifications where event = 'budget.used'
             and user_id = '22222222-0000-0000-0000-0000000000a1' and payload ->> 'campaign_id' = '55555555-0000-0000-0000-000000000001'),
          array['50'], '50% terpakai → budget.used');
select is(market.run_budget_alerts(), 0, 'dijalankan ulang tanpa perubahan → tidak ada notifikasi');
select is((select count(*)::int from ops.notifications where event = 'budget.used'
             and user_id = '22222222-0000-0000-0000-0000000000a1' and payload ->> 'campaign_id' = '55555555-0000-0000-0000-000000000001'),
          1, 'ambang yang sama tidak dikirim ulang');
update finance.reward_pools set allocated = 850000 where id = '66666666-0000-0000-0000-000000000001';
select is(market.run_budget_alerts(), 2, '80% terpakai → 2 penerima');
update finance.reward_pools set allocated = 1000000 where id = '66666666-0000-0000-0000-000000000001';
select is(market.run_budget_alerts(), 2, '100% terpakai → 2 penerima');
select is((select array_agg(payload ->> 'pct' order by id) from ops.notifications where event = 'budget.used'
             and user_id = '22222222-0000-0000-0000-0000000000a1' and payload ->> 'campaign_id' = '55555555-0000-0000-0000-000000000001'),
          array['50', '80', '100'], '50/80/100% masing-masing sekali');
select ok((select bool_and(payload ->> 'campaign_title' = 'Film Satu' and payload ->> 'org_name' = 'Studio Satu') from ops.notifications
             where event = 'budget.used' and payload ->> 'campaign_id' = '55555555-0000-0000-0000-000000000001'),
          'payload budget.used: campaign_title + org_name');
select is((select count(*)::int from ops.notifications where event = 'budget.used'
             and payload ->> 'campaign_id' = '55555555-0000-0000-0000-000000000001'), 6, 'penerima: brand_owner + brand_manager');
select is((select array_agg(payload ->> 'pct') from ops.notifications where event = 'budget.used'
             and user_id = '22222222-0000-0000-0000-0000000000a1' and payload ->> 'campaign_id' = '55555555-0000-0000-0000-000000000003'),
          array['100'], 'beberapa ambang terlewati sekaligus → hanya yang tertinggi dikirim');
select is((select count(*)::int from market.budget_alerts where campaign_id = '55555555-0000-0000-0000-000000000003'), 3,
          'semua ambang yang terlewati tercatat (tidak dikirim lagi nanti)');
select is((select count(*)::int from ops.notifications where event = 'budget.projection_low'
             and user_id = '22222222-0000-0000-0000-0000000000a1' and payload ->> 'campaign_id' = '55555555-0000-0000-0000-000000000006'),
          1, 'proyeksi pemakaian < 50% → budget.projection_low sekali');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select is((select array_agg(kind order by kind) from api.budget_alerts where campaign_id = '55555555-0000-0000-0000-000000000001'),
          array['used_100', 'used_50', 'used_80'], 'anggota org membaca alert campaign org-nya (api.budget_alerts)');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select is((select count(*)::int from api.budget_alerts), 0, 'clipper tidak melihat alert budget brand');
reset role;

-- ---------- broadcast (F-A12, job:broadcast-dispatch) ----------
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_moderator}', 'aal2');
select throws_ok($$ select api.send_broadcast('Judul', 'Isi') $$, '42501', 'auth:forbidden', 'broadcast = admin_ops');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', '{admin_ops}', 'aal2');
select throws_ok($$ select api.send_broadcast('Judul', 'Isi', '{"negara":"id"}') $$, 'P0001', 'invalid:segment', 'segmen tak dikenal ditolak');
insert into t_ids (k, id) select 'bc1', api.send_broadcast('Campaign baru TikTok', 'Ada campaign baru!',
  '{"platforms":["tiktok"],"min_trust_score":50}', '{in_app,email}');
insert into t_ids (k, id) select 'bc2', api.send_broadcast('Khusus KYC', 'Halo', '{"kyc":"approved"}', '{in_app}');
insert into t_ids (k, id) select 'bc3', api.send_broadcast('Nanti', 'Besok', '{}', '{in_app}', now() + interval '1 day');
reset role;
select is(ops.dispatch_broadcasts(), 3, 'dispatch: penerima sesuai segmen (2 + 1), broadcast terjadwal nanti belum dikirim');
select is((select array_agg(p.username order by p.username) from ops.notifications n join market.profiles p on p.id = n.user_id
            where n.event = 'broadcast.sent' and n.payload ->> 'broadcast_id' = (select id from t_ids where k = 'bc1')::text),
          array['andi', 'eko'], 'segmen platform + Trust Score (suspend & skor rendah tidak ikut)');
select is((select array_agg(p.username) from ops.notifications n join market.profiles p on p.id = n.user_id
            where n.event = 'broadcast.sent' and n.payload ->> 'broadcast_id' = (select id from t_ids where k = 'bc2')::text),
          array['budi'], 'segmen KYC dari keputusan KYC yang dicatat core');
select is((select array_agg(p.username) from pgmq.q_email m join market.profiles p on p.id = (m.message ->> 'user_id')::uuid
            where m.message ->> 'event' = 'broadcast.sent'),
          array['eko'], 'email promosi ikut preferensi (Andi mematikan) dan hanya untuk kanal email');
select is((select array_agg(coalesce(recipient_count::text, 'null') order by title) from ops.broadcasts),
          array['2', '1', 'null'], 'recipient_count tercatat; yang terjadwal nanti belum terkirim');
select is(ops.dispatch_broadcasts(), 0, 'broadcast tidak dikirim dua kali');

-- ---------- job:trust-score (F-C12) ----------
insert into trust.score_events (user_id, delta, reason, created_by) values
  ('11111111-0000-0000-0000-00000000000e', 70, 'admin_override', '33333333-0000-0000-0000-0000000000ad'),
  ('11111111-0000-0000-0000-00000000000b', -80, 'fraud_flag', null);
select is(trust.recalc_scores(), 5, 'trust-score menulis profil yang skornya berubah saja');
select is((select array_agg(username || ':' || trust_score order by username) from market.profiles
            where username in ('andi', 'budi', 'citra', 'eko')),
          array['andi:51', 'budi:0', 'citra:50', 'eko:100'], 'skor = 50 + Σ delta, dibatasi 0–100');
select is(trust.recalc_scores(), 0, 'dijalankan ulang tanpa perubahan');
-- Regresi G-3: umur akun bersih (30 hari tanpa reject/fraud) menaikkan skor sekali per periode.
update market.profiles set created_at = now() - interval '31 days' where username = 'citra';
select is(trust.recalc_scores(), 1, 'regresi G-3: clean_tenure menaikkan skor profil bersih');
select is((select trust_score from market.profiles where username = 'citra'), 51::smallint, 'citra 50 → 51');
select is(trust.recalc_scores(), 0, 'clean_tenure sekali per periode 30 hari');

-- ---------- Perbaikan integrasi 2026-10-19 ----------
reset role;
-- Tier tiered_cpm wajib kontigu: tumpang tindih membuat views yang sama dibayar dua kali (finance.rule_amount).
select lives_ok($$ select market.check_rule_params('tiered_cpm', '{"tiers":[{"from":0,"to":50000,"rate":2000},{"from":50000,"rate":1500}]}') $$,
                'tier kontigu, tier terakhir terbuka: diterima');
select throws_ok($$ select market.check_rule_params('tiered_cpm', '{"tiers":[{"from":0,"to":"1e4","rate":2000}]}') $$,
                 'P0001', 'invalid:rule_params', 'regresi R8: batas tier bukan angka (dibaca accrual sebagai plafon) ditolak');
select throws_ok($$ select market.check_rule_params('tiered_cpm', '{"tiers":[{"from":0,"to":60000,"rate":2000},{"from":50000,"rate":1500}]}') $$,
                 'P0001', 'invalid:rule_params', 'tier tumpang tindih ditolak');
select throws_ok($$ select market.check_rule_params('tiered_cpm', '{"tiers":[{"from":0,"rate":2000},{"from":50000,"rate":1500}]}') $$,
                 'P0001', 'invalid:rule_params', 'tier terbuka yang bukan terakhir ditolak');
select throws_ok($$ select market.check_rule_params('tiered_cpm', '{"tiers":[{"from":0,"to":40000,"rate":2000},{"from":50000,"rate":1500}]}') $$,
                 'P0001', 'invalid:rule_params', 'celah antar tier ditolak');

-- Paket managed: brand mengajukan sendiri tanpa menunggu tim → invoice jasa managed tetap terbit (sekali).
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
insert into t_ids (k, id) select 'c_mgd', api.save_campaign($j${
  "org_id":"44444444-0000-0000-0000-000000000001","title":"Managed Sendiri","type":"clipping","platforms":["tiktok"],
  "service_mode":"managed","managed_brief":"Tolong buatkan brief dari trailer kami.",
  "start_at":"2099-01-01T00:00:00Z","submit_deadline":"2099-01-20T00:00:00Z",
  "pools":[{"key":"idr","reward_type_id":"77777777-0000-0000-0000-000000000001","total":1000000,"max_per_clip":100000}],
  "rules":[{"kind":"per_1k_views","pool":"idr","params":{"rate":2000}}]}$j$::jsonb, true);
reset role;
select is((select count(*)::int from finance.invoices where campaign_id = (select id from t_ids where k = 'c_mgd') and kind = 'managed_service'),
          1, 'brand mengajukan draft managed sendiri → invoice managed_service terbit');
select is((select service_fee from finance.invoices where campaign_id = (select id from t_ids where k = 'c_mgd') and kind = 'managed_service'),
          2500000::numeric, 'jasa managed = public.billing.managed_service_idr');
select is((select managed_brief from market.campaigns where id = (select id from t_ids where k = 'c_mgd')),
          'Tolong buatkan brief dari trailer kami.', 'brief mentah managed tersimpan terpisah dari brief final');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select is((select api.campaign_detail((select id from t_ids where k = 'c_mgd')) #>> '{campaign,managed_brief}'),
          'Tolong buatkan brief dari trailer kami.', 'anggota org melihat brief mentah di campaign_detail');
select is((select managed_brief from api.managed_briefs where campaign_id = (select id from t_ids where k = 'c_mgd')),
          'Tolong buatkan brief dari trailer kami.', 'anggota org melihat brief mentah lewat api.managed_briefs');
reset role;
-- Trigger brief beku memakai kode mesin (UI memetakan kode, bukan teks).
select throws_ok($$ update market.campaigns set brief = 'ganti' where id = (select id from t_ids where k = 'c_mgd') $$,
                 '23514', 'campaign_locked', 'trigger brief beku: pesan = kode campaign_locked');

-- Keputusan owner 2026-10-19: batal sebelum live → jasa managed yang sudah dibayar ikut dikembalikan (refund E-35 + jurnal balik).
insert into t_ids (k, id) select 'inv_mgd', id from finance.invoices
 where campaign_id = (select id from t_ids where k = 'c_mgd') and kind = 'managed_service';
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000ad', array['admin_finance'], 'aal2');
select lives_ok($$ select api.confirm_invoice_payment((select id from t_ids where k = 'inv_mgd'),
                    (select total from api.invoices where id = (select id from t_ids where k = 'inv_mgd')), now(), 'REF-MGD-1', 'transfer') $$,
                'jasa managed dibayar');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select lives_ok($$ select api.control_campaign((select id from t_ids where k = 'c_mgd'), 'end_early') $$, 'brand membatalkan sebelum live');
reset role;
select is((select amount from finance.org_refunds where campaign_id = (select id from t_ids where k = 'c_mgd')),
          (select total from finance.invoices where id = (select id from t_ids where k = 'inv_mgd')),
          'refund batal = jasa managed + pajak yang sudah dibayar');
select is((select sum(e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
            where e.ref_type = 'refund' and a.owner_type = 'platform_revenue'
              and e.ref_id = (select id::text from finance.org_refunds where campaign_id = (select id from t_ids where k = 'c_mgd'))),
          -(select service_fee from finance.invoices where id = (select id from t_ids where k = 'inv_mgd')), 'revenue jasa managed dibalik');

select * from finish();
rollback;
