-- Mesin uang & RPC service core: accrual §10.5, release, payout/batch/instant, invoice, refund, referral, fraud queue, lifecycle,
-- RPC worker/bridge (service_role), alert & overview admin. Jalankan: supabase test db --workdir db/core
begin;
-- Fixture tes tidak bergantung seed.sql; di-rollback di akhir.
truncate ops.settings, market.categories, finance.fee_rules, market.reward_types, ops.alerts cascade;
select no_plan();

insert into ops.settings (key, value) values
  ('auth.identity_issuer', '"https://auth.contoh.id/auth/v1"'),
  ('public.finance.min_withdraw_idr', '100000'),
  ('public.finance.instant_min_trust', '70'),
  ('public.flags.instant_withdraw', 'false'),
  ('public.market.max_accounts_per_platform', '3'),
  ('finance.hold_days', '7'),
  ('finance.settlement_threshold_pct', '5'),
  ('finance.settlement_wait_hours', '6'),
  ('finance.referral_bonus_pct', '5'),
  ('finance.referral_bonus_days', '90'),
  ('finance.refund_transfer_fee_idr', '2500'),
  ('tracking.final_grace_hours', '72'),
  ('tracking.poll_schedule', '[{"until_hours":72,"every_hours":4},{"until_hours":336,"every_hours":24},{"until_hours":null,"every_hours":72}]'),
  ('trust.fraud.like_rate_min', '0.005'),
  ('trust.fraud.spike_multiplier', '10'),
  ('trust.fraud.new_account_days', '14'),
  ('trust.fraud.new_account_views', '100000'),
  ('trust.fraud.views_over_reach', '3'),
  ('trust.fraud.lock_drop_pct', '20'),
  ('trust.fraud.flag_spike_per_hour', '20');
insert into finance.fee_rules (scope, instant_withdraw_fee) values ('global', 5000);
insert into market.profiles (id, username, display_name, trust_score) values
  ('11111111-0000-0000-0000-00000000000a', 'andi', 'Andi', 80),
  ('11111111-0000-0000-0000-00000000000b', 'budi', 'Budi', 40),
  ('11111111-0000-0000-0000-00000000000c', 'citra', 'Citra', 50),
  ('11111111-0000-0000-0000-00000000000d', 'dedi', 'Dedi', 50),
  ('11111111-0000-0000-0000-00000000000e', 'eko', 'Eko', 50),
  ('11111111-0000-0000-0000-00000000000f', 'fani', 'Fani', 50),
  ('22222222-0000-0000-0000-0000000000a1', 'owner1', 'Owner 1', 50),
  ('22222222-0000-0000-0000-0000000000c1', 'finance1', 'Finance 1', 50);
insert into market.organizations (id, name, org_type, legal_name, npwp, address, status, verified_by, verified_at, created_by) values
  ('44444444-0000-0000-0000-000000000001', 'Studio Satu', 'badan', 'PT Studio Satu', '0123456789012345', 'Jakarta', 'verified',
   '33333333-0000-0000-0000-0000000000f1', now(), '33333333-0000-0000-0000-0000000000f1');
insert into market.org_members (org_id, user_id, role) values
  ('44444444-0000-0000-0000-000000000001', '22222222-0000-0000-0000-0000000000a1', 'brand_owner'),
  ('44444444-0000-0000-0000-000000000001', '22222222-0000-0000-0000-0000000000c1', 'brand_finance');
insert into market.reward_types (id, owner_org_id, code, name, kind, unit_label, idr_value_per_unit, decimals, fulfillment, recipient_schema) values
  ('77777777-0000-0000-0000-000000000001', null, 'IDR', 'Rupiah', 'cash', 'Rp', 1, 0, 'payout', '[]'),
  ('77777777-0000-0000-0000-000000000002', '44444444-0000-0000-0000-000000000001', 'DIAMOND', 'Diamonds', 'in_game', 'Diamonds', 300, 0,
   'manual_export', '[{"key":"game_user_id","pii":false,"required":true},{"key":"address","pii":true}]'),
  ('77777777-0000-0000-0000-000000000003', '44444444-0000-0000-0000-000000000001', 'VOUCHER', 'Voucher', 'voucher_code', 'voucher', 50000, 0,
   'code_pool', '[]');
insert into tracking.social_accounts (id, user_id, platform, external_id, handle, platform_created_at) values
  ('99999999-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-00000000000a', 'tiktok', 'tt-andi', '@andi', now() - interval '2 years'),
  ('99999999-0000-0000-0000-0000000000a2', '11111111-0000-0000-0000-00000000000a', 'instagram', 'ig-andi', '@andi.ig', now() - interval '2 years'),
  ('99999999-0000-0000-0000-00000000000b', '11111111-0000-0000-0000-00000000000b', 'tiktok', 'tt-budi', '@budi', now() - interval '2 years'),
  ('99999999-0000-0000-0000-00000000000c', '11111111-0000-0000-0000-00000000000c', 'tiktok', 'tt-citra', '@citra', now() - interval '2 years'),
  ('99999999-0000-0000-0000-00000000000d', '11111111-0000-0000-0000-00000000000d', 'tiktok', 'tt-dedi', '@dedi', now() - interval '2 years'),
  ('99999999-0000-0000-0000-00000000000e', '11111111-0000-0000-0000-00000000000e', 'tiktok', 'tt-eko', '@eko', now() - interval '2 years'),
  ('99999999-0000-0000-0000-00000000000f', '11111111-0000-0000-0000-00000000000f', 'tiktok', 'tt-fani', '@fani', now() - interval '2 years');

-- Helper tes (pg_temp, ikut hilang saat rollback)
create function pg_temp.mk_campaign(p_id uuid, p_slug text, p_min_views int default 1000, p_review text default 'auto',
                                    p_window int default 30) returns uuid
language plpgsql as $$
begin
  insert into market.campaigns (id, org_id, slug, title, type, platforms, start_at, submit_deadline, created_by, min_views, review_mode,
                                view_window_days)
  values (p_id, '44444444-0000-0000-0000-000000000001', p_slug, 'Campaign ' || p_slug, 'clipping', '{tiktok}', now() - interval '20 days',
          now() + interval '10 days', '22222222-0000-0000-0000-0000000000a1', p_min_views, p_review, p_window);
  update market.campaigns set status = 'in_review' where id = p_id;
  update market.campaigns set status = 'scheduled' where id = p_id;
  update market.campaigns set status = 'live' where id = p_id;
  return p_id;
end $$;
create function pg_temp.mk_pool(p_campaign uuid, p_pool uuid, p_total numeric, p_max numeric,
                                p_rt uuid default '77777777-0000-0000-0000-000000000001') returns uuid
language plpgsql as $$
begin
  insert into finance.reward_pools (id, campaign_id, reward_type_id, total, max_per_clip) values (p_pool, p_campaign, p_rt, p_total, p_max);
  -- dana pool masuk (setara confirm_invoice_payment) supaya saldo akun pool = total
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(finance.account('bank_clearing', null, p_rt), -p_total, 'invoice_payment', 'fixture:' || p_pool),
    finance.e(finance.account('campaign_pool', p_pool, p_rt), p_total, 'invoice_payment', 'fixture:' || p_pool)));
  return p_pool;
end $$;
create function pg_temp.mk_rule(p_campaign uuid, p_pool uuid, p_kind text, p_params jsonb, p_from timestamptz default now() - interval '30 days',
                                p_to timestamptz default null, p_platform market.platform default null,
                                p_rt uuid default '77777777-0000-0000-0000-000000000001') returns uuid
language plpgsql as $$
declare rid uuid;
begin
  insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, platform, params, effective_from, effective_to)
  values (p_campaign, p_kind, p_rt, p_pool, p_platform, p_params, p_from, p_to) returning id into rid;
  return rid;
end $$;
create function pg_temp.mk_sub(p_campaign uuid, p_user uuid, p_post text, p_posted timestamptz default now() - interval '1 day')
returns uuid
language plpgsql as $$
declare cid uuid; sid uuid;
begin
  insert into market.claims (campaign_id, user_id, expires_at, created_at) values (p_campaign, p_user, now() + interval '48 hours', p_posted - interval '1 hour')
  returning id into cid;
  insert into tracking.submissions (claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at)
  values (cid, p_user, p_campaign, (select a.id from tracking.social_accounts a where a.user_id = p_user and a.platform = 'tiktok'),
          'tiktok', p_post, 'https://tiktok.com/v/' || p_post, p_posted) returning id into sid;
  update market.claims set status = 'submitted' where id = cid;
  update tracking.submissions set status = 'tracking', next_poll_at = now() + interval '4 hours' where id = sid;
  return sid;
end $$;
create function pg_temp.snap(p_sub uuid, p_views bigint, p_at timestamptz default null, p_final boolean default false) returns bigint
language plpgsql as $$
declare vid bigint;
begin
  insert into tracking.view_snapshots (submission_id, taken_at, views, is_final) values (p_sub, coalesce(p_at, clock_timestamp()), p_views, p_final)
  returning id into vid;
  perform finance.accrue_earnings(p_sub, vid);
  return vid;
end $$;
create function pg_temp.bal(p_user uuid, p_state text, p_rt uuid default '77777777-0000-0000-0000-000000000001') returns numeric
language sql security definer as $$
  select coalesce(sum(e.amount), 0) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
   where a.owner_type = 'user_wallet' and a.owner_id = p_user and a.reward_type_id = p_rt and e.state::text = p_state
$$;
create function pg_temp.acct(p_type text, p_owner uuid, p_rt uuid default '77777777-0000-0000-0000-000000000001') returns numeric
language sql security definer as $$
  select coalesce(sum(e.amount), 0) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
   where a.owner_type = p_type and a.owner_id is not distinct from p_owner and a.reward_type_id = p_rt
$$;
create function pg_temp.rule_amt(p_sub uuid, p_rule uuid) returns numeric
language sql as $$ select coalesce((select ce.amount from finance.clip_earnings ce where ce.submission_id = p_sub and ce.rule_id = p_rule), 0) $$;
create function pg_temp.jwt(p_sub text, p_extra jsonb default '{}') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', (jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'aal', 'aal1',
                                                               'iss', 'https://auth.contoh.id/auth/v1') || p_extra)::text, true);
end $$;
grant execute on all functions in schema pg_temp to authenticated;

-- ========== A. Accrual (§10.5) ==========
-- K1: per_1k Rp2.000, min_views 1.000, cap per klip Rp100.000
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000a1', 'k1-cpm');
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000a1', '66666666-0000-0000-0000-0000000000a1', 1000000, 100000);
create temp table t_ids (k text primary key, v text);
create temp table t_pay (k text primary key, id uuid);
grant all on t_pay, t_ids to authenticated;
insert into t_ids select 'r_k1', pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a1', '66666666-0000-0000-0000-0000000000a1', 'per_1k_views', '{"rate":2000}');
insert into t_ids select 's1', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a1', '11111111-0000-0000-0000-00000000000a', 'v1');

select pg_temp.snap((select v::uuid from t_ids where k = 's1'), 500);
select is((select counted_views from tracking.submissions where id = (select v::uuid from t_ids where k = 's1')), 0::bigint,
          'min_views: di bawah 1.000 views belum dihitung');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'pending'), 0::numeric, 'min_views: belum ada earning');
insert into t_ids select 'snap_5k', pg_temp.snap((select v::uuid from t_ids where k = 's1'), 5000)::text;
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'pending'), 10000::numeric,
          'min_views tembus: semua 5.000 views dibayar (Rp10.000 pending)');
select is((select count(*)::int from finance.ledger_entries where ref_type = 'accrual'
           and ref_id = (select v from t_ids where k = 'snap_5k') || ':' || (select v from t_ids where k = 'r_k1')), 2,
          'accrual = 2 entri dengan ref_id snapshot:rule');
select finance.accrue_earnings((select v::uuid from t_ids where k = 's1'), (select v::bigint from t_ids where k = 'snap_5k'));
select finance.accrue_earnings((select v::uuid from t_ids where k = 's1'), (select v::bigint from t_ids where k = 'snap_5k'));
select is((select count(*)::int from finance.ledger_entries where ref_type = 'accrual'), 2, 'accrual snapshot sama diulang = no-op');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'pending'), 10000::numeric, 'saldo pending tidak berubah saat diulang');
select pg_temp.snap((select v::uuid from t_ids where k = 's1'), 80000);
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'pending'), 100000::numeric, 'cap per klip: berhenti di Rp100.000');
select pg_temp.snap((select v::uuid from t_ids where k = 's1'), 200000);
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'pending'), 100000::numeric, 'cap per klip: snapshot berikutnya tidak menambah');
select is((select allocated from finance.reward_pools where id = '66666666-0000-0000-0000-0000000000a1'), 100000::numeric,
          'pool.allocated ikut bertambah di transaksi yang sama');

-- K2: tiered + milestone + flat + rule khusus instagram
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000a2', 'k2-mix');
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000a2', '66666666-0000-0000-0000-0000000000a2', 10000000, 1000000);
insert into t_ids select 'r_tier', pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a2', '66666666-0000-0000-0000-0000000000a2', 'tiered_cpm',
  '{"tiers":[{"from":0,"to":50000,"rate":2000},{"from":50000,"to":null,"rate":1500}]}');
insert into t_ids select 'r_mile', pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a2', '66666666-0000-0000-0000-0000000000a2', 'milestone_bonus',
  '{"threshold":100000,"amount":50000}');
insert into t_ids select 'r_flat', pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a2', '66666666-0000-0000-0000-0000000000a2', 'flat_per_post',
  '{"amount":25000}');
insert into t_ids select 'r_ig', pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a2', '66666666-0000-0000-0000-0000000000a2', 'per_1k_views',
  '{"rate":9999}', p_platform => 'instagram');
insert into t_ids select 's2', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a2', '11111111-0000-0000-0000-00000000000b', 'v2');
select pg_temp.snap((select v::uuid from t_ids where k = 's2'), 60000);
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's2'), (select v::uuid from t_ids where k = 'r_tier')), 115000::numeric,
          'tiered: 50rb × Rp2.000 + 10rb × Rp1.500');
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's2'), (select v::uuid from t_ids where k = 'r_flat')), 25000::numeric,
          'flat_per_post dibayar di accrual pertama');
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's2'), (select v::uuid from t_ids where k = 'r_mile')), 0::numeric,
          'milestone belum tembus');
select pg_temp.snap((select v::uuid from t_ids where k = 's2'), 120000);
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's2'), (select v::uuid from t_ids where k = 'r_tier')), 205000::numeric,
          'tiered lanjut di tier 2 (+60rb × Rp1.500)');
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's2'), (select v::uuid from t_ids where k = 'r_mile')), 50000::numeric,
          'milestone dibayar sekali saat threshold dilewati');
select pg_temp.snap((select v::uuid from t_ids where k = 's2'), 130000);
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's2'), (select v::uuid from t_ids where k = 'r_mile'))
          + pg_temp.rule_amt((select v::uuid from t_ids where k = 's2'), (select v::uuid from t_ids where k = 'r_flat')), 75000::numeric,
          'milestone & flat tidak dibayar dua kali');
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's2'), (select v::uuid from t_ids where k = 'r_ig')), 0::numeric,
          'rule khusus instagram tidak membayar submisi tiktok');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000b', 'pending'), 295000::numeric, 'total pending budi = jumlah semua rule');

-- K3: pool kurang → alokasi sebagian, rule berhenti; semua pool habis → campaign exhausted
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000a3', 'k3-habis');
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000a3', '66666666-0000-0000-0000-0000000000a3', 30000, 1000000);
select pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a3', '66666666-0000-0000-0000-0000000000a3', 'per_1k_views', '{"rate":2000}');
insert into t_ids select 's3a', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a3', '11111111-0000-0000-0000-00000000000c', 'v3a');
insert into t_ids select 's3b', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a3', '11111111-0000-0000-0000-00000000000d', 'v3b');
select pg_temp.snap((select v::uuid from t_ids where k = 's3a'), 10000);
select is((select status::text from market.campaigns where id = '55555555-0000-0000-0000-0000000000a3'), 'live', 'pool masih ada: campaign live');
select pg_temp.snap((select v::uuid from t_ids where k = 's3b'), 10000);
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000d', 'pending'), 10000::numeric, 'pool kurang: sisa Rp10.000 dialokasikan sebagian');
select is((select total - allocated from finance.reward_pools where id = '66666666-0000-0000-0000-0000000000a3'), 0::numeric, 'pool habis tepat 0');
select is((select status::text from market.campaigns where id = '55555555-0000-0000-0000-0000000000a3'), 'exhausted',
          'semua pool habis → campaign exhausted (S-01)');
select pg_temp.snap((select v::uuid from t_ids where k = 's3a'), 20000);
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000c', 'pending'), 20000::numeric, 'pool habis: rule berhenti membayar');

-- K4: settlement mode — sisa < 5% → cut-off, sisa dibagi pro-rata tepat (recehan 1e-10 dibagikan)
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000a4', 'k4-settle', 0);
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000a4', '66666666-0000-0000-0000-0000000000a4', 100000, 1000000);
select pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a4', '66666666-0000-0000-0000-0000000000a4', 'per_1k_views', '{"rate":1000}');
insert into t_ids select 's4a', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a4', '11111111-0000-0000-0000-00000000000a', 'v4a');
insert into t_ids select 's4b', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a4', '11111111-0000-0000-0000-00000000000b', 'v4b');
insert into t_ids select 's4c', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a4', '11111111-0000-0000-0000-00000000000c', 'v4c');
insert into t_ids select 's4d', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a4', '11111111-0000-0000-0000-00000000000d', 'v4d');
select pg_temp.snap((select v::uuid from t_ids where k = 's4a'), 99000);
select ok(exists (select 1 from finance.pool_settlements where pool_id = '66666666-0000-0000-0000-0000000000a4'),
          'sisa 1% < 5% → settlement mode dengan cut-off');
select ok((select bool_and(next_poll_at <= now()) from tracking.submissions where campaign_id = '55555555-0000-0000-0000-0000000000a4'),
          'settlement: semua submisi campaign diminta poll sekarang');
select pg_temp.snap((select v::uuid from t_ids where k = k1), 1000) from (values ('s4b'), ('s4c'), ('s4d')) x(k1);
select is((select sum(demand) from finance.clip_earnings where pool_id = '66666666-0000-0000-0000-0000000000a4'), 3000::numeric,
          'settlement: Δ setelah cut-off dicatat sebagai demand, belum dijurnal');
select is((select total - allocated from finance.reward_pools where id = '66666666-0000-0000-0000-0000000000a4'), 1000::numeric,
          'settlement: sisa pool belum dibagi sebelum finalisasi');
update tracking.submissions set last_snapshot_at = now() where campaign_id = '55555555-0000-0000-0000-0000000000a4';
select finance.finalize_settlements();
select is((select sum(amount) from finance.clip_earnings where pool_id = '66666666-0000-0000-0000-0000000000a4'
            and submission_id <> (select v::uuid from t_ids where k = 's4a')), 1000::numeric,
          'pro-rata: sisa Rp1.000 dibagi tepat habis ke 3 submisi');
select ok((select max(amount) - min(amount) <= 0.0000000001 from finance.clip_earnings where pool_id = '66666666-0000-0000-0000-0000000000a4'
            and submission_id <> (select v::uuid from t_ids where k = 's4a')), 'pro-rata: jatah sama untuk Δ sama (selisih ≤ 1e-10)');
select is((select status::text from market.campaigns where id = '55555555-0000-0000-0000-0000000000a4'), 'exhausted',
          'settlement selesai, pool habis → exhausted');
select ok(not exists (select 1 from finance.pool_settlements where pool_id = '66666666-0000-0000-0000-0000000000a4'), 'settlement mode berakhir');

-- K5: raise_rate — rule lama ditutup, rule baru berlaku untuk snapshot sesudahnya
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000a5', 'k5-raise');
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000a5', '66666666-0000-0000-0000-0000000000a5', 1000000, 1000000);
insert into t_ids select 'r_old', pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a5', '66666666-0000-0000-0000-0000000000a5', 'per_1k_views',
  '{"rate":2000}', now() - interval '30 days', now() - interval '1 day');
insert into t_ids select 'r_new', pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a5', '66666666-0000-0000-0000-0000000000a5', 'per_1k_views',
  '{"rate":3000}', now() - interval '1 day');
insert into t_ids select 's5', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a5', '11111111-0000-0000-0000-00000000000c', 'v5',
                                              now() - interval '5 days');
select pg_temp.snap((select v::uuid from t_ids where k = 's5'), 2000, now() - interval '2 days');
select pg_temp.snap((select v::uuid from t_ids where k = 's5'), 5000, now() - interval '1 hour');
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's5'), (select v::uuid from t_ids where k = 'r_old')), 4000::numeric,
          'raise_rate: snapshot sebelum effective_to memakai rate lama');
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's5'), (select v::uuid from t_ids where k = 'r_new')), 9000::numeric,
          'raise_rate: Δ sesudahnya memakai rate baru');

-- K6: views turun saat lock → pending dikoreksi turun (jurnal reversal)
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000a6', 'k6-drop');
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000a6', '66666666-0000-0000-0000-0000000000a6', 1000000, 1000000);
select pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a6', '66666666-0000-0000-0000-0000000000a6', 'per_1k_views', '{"rate":2000}');
insert into t_ids select 's6', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a6', '11111111-0000-0000-0000-00000000000e', 'v6');
select pg_temp.snap((select v::uuid from t_ids where k = 's6'), 10000);
select pg_temp.snap((select v::uuid from t_ids where k = 's6'), 7000, null, true);
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000e', 'pending'), 14000::numeric, 'views turun 10rb → 7rb saat lock: pending jadi Rp14.000');
select is((select counted_views from tracking.submissions where id = (select v::uuid from t_ids where k = 's6')), 7000::bigint,
          'counted_views ikut turun ke snapshot final');
select is((select allocated from finance.reward_pools where id = '66666666-0000-0000-0000-0000000000a6'), 14000::numeric,
          'koreksi turun mengembalikan Rp6.000 ke pool');

-- ========== B. Release (lock + hold, tanpa fraud flag, pembulatan ke bawah) ==========
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000a7', 'k7-release', 0);
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000a7', '66666666-0000-0000-0000-0000000000a7', 1000000, 1000000);
select pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a7', '66666666-0000-0000-0000-0000000000a7', 'per_1k_views', '{"rate":2500}');
insert into t_ids select 's7', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a7', '11111111-0000-0000-0000-00000000000a', 'v7');
insert into t_ids select 's7b', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a7', '11111111-0000-0000-0000-00000000000b', 'v7b');
insert into t_ids select 's7c', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a7', '11111111-0000-0000-0000-00000000000c', 'v7c');
select pg_temp.snap((select v::uuid from t_ids where k = k1), 1001) from (values ('s7'), ('s7b'), ('s7c')) x(k1);
update tracking.submissions set status = 'locked', locked_at = now() - interval '8 days'
 where id in (select v::uuid from t_ids where k in ('s7', 's7c'));
update tracking.submissions set status = 'locked', locked_at = now() - interval '1 day' where id = (select v::uuid from t_ids where k = 's7b');
select trust.raise_flag('submission', (select v::uuid from t_ids where k = 's7c'), 'FR-01', 50, '{}');
-- s1 (andi, K1) masih tracking: tidak ikut dirilis
select finance.release_earnings();
select is((select status::text from tracking.submissions where id = (select v::uuid from t_ids where k = 's7')), 'settled',
          'lock + hold 7 hari → submisi settled');
select is((select sum(e.amount) from finance.ledger_entries e where e.ref_type = 'release' and e.state = 'available'
            and e.ref_id like (select v from t_ids where k = 's7') || ':%'), 2502::numeric,
          'Rp2.502,5 pending → Rp2.502 Tersedia (dibulatkan ke bawah)');
select is((select e.amount from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
           where e.ref_type = 'release' and a.owner_type = 'campaign_pool'), 0.5::numeric, 'recehan Rp0,5 kembali ke pool');
select is((select status::text from tracking.submissions where id = (select v::uuid from t_ids where k = 's7b')), 'locked',
          'hold belum lewat → belum dirilis');
select is((select status::text from tracking.submissions where id = (select v::uuid from t_ids where k = 's7c')), 'locked',
          'fraud flag terbuka → tidak dirilis');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'pending'), 199000::numeric, 'pending andi tinggal K1 + K4 (belum lock)');
select is((select count(*)::int from ops.notifications where event = 'earning.available'
           and user_id = '11111111-0000-0000-0000-00000000000a'), 1, 'notifikasi earning tersedia');
select finance.release_earnings();
select is((select count(*)::int from finance.ledger_entries where ref_type = 'release' and state = 'available'), 1, 'release diulang = no-op');

-- Invarian uang
select is((select count(*)::int from (select 1 from finance.ledger_entries e group by e.txn_id, e.reward_type_id having sum(e.amount) <> 0) x),
          0, 'ledger seimbang per transaksi per reward type');
select is((select count(*)::int from finance.reward_pools rp
            where rp.allocated <> coalesce((select -sum(e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                                            where a.owner_type = 'campaign_pool' and a.owner_id = rp.id
                                              and e.ref_type in ('accrual', 'reversal', 'release')), 0)), 0,
          'reward_pools.allocated = cache jurnal pool (accrual − reversal − recehan release)');
select is((select count(*)::int from finance.reward_pools rp
            where pg_temp.acct('campaign_pool', rp.id, rp.reward_type_id) <> rp.total - rp.allocated), 0,
          'saldo akun pool = total − allocated');
select is((select count(*)::int from finance.reward_pools rp
            where rp.allocated <> (select coalesce(sum(ce.amount), 0) from finance.clip_earnings ce where ce.pool_id = rp.id)
                                  - coalesce((select sum(e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                                              where a.owner_type = 'campaign_pool' and a.owner_id = rp.id and e.ref_type = 'release'), 0)), 0,
          'clip_earnings konsisten dengan allocated pool');

-- ========== C. Payout (F-C09, F-C15) ==========
select finance.post(gen_random_uuid(), jsonb_build_array(
  finance.e(finance.account('platform_revenue', null, '77777777-0000-0000-0000-000000000001'), -1000000, 'adjustment', 'fixture:andi'),
  finance.e(finance.account('user_wallet', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000001'), 1000000,
            'adjustment', 'fixture:andi', 'available')));
insert into market.referrals (referred_id, referrer_id, code) values ('11111111-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-00000000000d', 'dedi0001');
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.request_payout(gen_random_uuid(), 200000, 'batch', 'idem-batch-1') $$, '42501', 'auth:kyc_required',
                 'payout tanpa KYC approved ditolak');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a', '{"kyc":"approved"}');
select throws_ok($$ select api.request_payout(gen_random_uuid(), 50000, 'batch', 'idem-small-1') $$, 'P0001', 'below_minimum',
                 'di bawah minimum withdraw ditolak');
select throws_ok($$ select api.request_payout(gen_random_uuid(), 1002503, 'batch', 'idem-big-01') $$, 'P0001', 'insufficient_balance',
                 'melebihi saldo Tersedia ditolak');
select throws_ok($$ select api.request_payout(gen_random_uuid(), 100000, 'instant', 'idem-inst-0') $$, 'P0001', 'instant_disabled',
                 'instant ditolak saat flag instant_withdraw mati');
select throws_ok($$ select api.request_payout(gen_random_uuid(), 100000.5, 'batch', 'idem-frac-1') $$, 'P0001', 'invalid:amount',
                 'nominal pecahan rupiah ditolak');
insert into t_pay select 'b1', (api.request_payout('aaaaaaaa-0000-0000-0000-0000000000b1', 200000, 'batch', 'idem-batch-1')).id;
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available'), 802502::numeric, 'payout batch: Tersedia berkurang Rp200.000');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'withdrawn'), 200000::numeric, 'payout batch: jurnal available → withdrawn');
select is((api.request_payout('aaaaaaaa-0000-0000-0000-0000000000b1', 200000, 'batch', 'idem-batch-1')).id, (select id from t_pay where k = 'b1'),
          'idempotency key sama → payout yang sama');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available'), 802502::numeric, 'replay tidak memotong saldo dua kali');
reset role;
select ok((select qualified_at is not null and bonus_until > now() + interval '89 days' from market.referrals
           where referred_id = '11111111-0000-0000-0000-00000000000a'), 'withdraw pertama dengan KYC → referral qualified');
update ops.settings set value = 'true' where key = 'public.flags.instant_withdraw';
update market.profiles set status = 'suspended', suspended_until = now() + interval '30 days' where id = '11111111-0000-0000-0000-00000000000c';
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000b', '{"kyc":"approved"}');
select throws_ok($$ select api.request_payout(gen_random_uuid(), 100000, 'instant', 'idem-budi-1') $$, 'P0001', 'trust_too_low',
                 'instant butuh Trust Score ≥ ambang');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000c', '{"kyc":"approved"}');
select throws_ok($$ select api.request_payout(gen_random_uuid(), 100000, 'batch', 'idem-citra-1') $$, 'P0001', 'profile_inactive',
                 'profil suspended tidak bisa withdraw');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a', '{"kyc":"approved"}');
insert into t_pay select 'i1', (api.request_payout('aaaaaaaa-0000-0000-0000-0000000000b1', 100000, 'instant', 'idem-inst-1')).id;
select is((select fee from api.payouts where id = (select id from t_pay where k = 'i1')), 5000::numeric, 'instant: biaya dari fee rule global');
reset role;
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available'), 702502::numeric, 'instant: Tersedia −Rp100.000');
select is(pg_temp.acct('platform_revenue', null) - (-1000000), 5000::numeric, 'instant: biaya masuk platform_revenue');
select ok(exists (select 1 from net.http_request_queue q where q.body ->> 'action' = 'disburse'
                  and q.body ->> 'payout_id' = (select id::text from t_pay where k = 'i1')), 'instant: bridge disburse dipanggil (alur 11)');
select is(api.bridge_get_payout((select id from t_pay where k = 'i1')) ->> 'net_amount', '95000.00', 'bridge_get_payout: transfer = amount − fee');
select api.bridge_mark_instant((select id from t_pay where k = 'i1'), 'failed', null, 'rekening tidak valid');
select is((select status::text from finance.payouts where id = (select id from t_pay where k = 'i1')), 'returned', 'instant gagal → returned');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available'), 802502::numeric, 'instant gagal: dana + biaya kembali ke Tersedia');
select is(pg_temp.acct('platform_revenue', null) - (-1000000), 0::numeric, 'instant gagal: biaya dikembalikan');
select ok(exists (select 1 from ops.alerts where kind = 'payout.failed' and payload ->> 'error' = 'rekening tidak valid'), 'alert payout gagal');
select is((select count(*)::int from ops.notifications where event = 'payout.failed'), 1, 'notifikasi payout gagal');
select api.bridge_mark_instant((select id from t_pay where k = 'i1'), 'failed', null, null);
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available'), 802502::numeric, 'mark_instant failed diulang = no-op');
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a', '{"kyc":"approved"}');
insert into t_pay select 'b2', (api.request_payout('aaaaaaaa-0000-0000-0000-0000000000b1', 150000, 'batch', 'idem-batch-2')).id;
insert into t_pay select 'b3', (api.request_payout('aaaaaaaa-0000-0000-0000-0000000000b1', 100000, 'batch', 'idem-batch-3')).id;
insert into t_pay select 'i2', (api.request_payout('aaaaaaaa-0000-0000-0000-0000000000b1', 100000, 'instant', 'idem-inst-2')).id;
insert into t_pay select 'i3', (api.request_payout('aaaaaaaa-0000-0000-0000-0000000000b1', 100000, 'instant', 'idem-inst-3')).id;
reset role;
select api.bridge_mark_instant((select id from t_pay where k = 'i2'), 'processing', null, null);
select api.bridge_mark_instant((select id from t_pay where k = 'i2'), 'paid', 'PRV-1', null);
select is((select status::text || ':' || provider_ref from finance.payouts where id = (select id from t_pay where k = 'i2')), 'paid:PRV-1',
          'instant sukses: paid + provider_ref');
select throws_ok($$ select api.bridge_mark_instant((select id from t_pay where k = 'i3'), 'paid', 'PRV-1', null) $$, '23505',
                 'duplicate_provider_ref', 'provider_ref sama untuk payout lain ditolak (satu payout = satu transfer)');

-- Batch: dua orang, export, hanya payout di CSV, gagal → saldo kembali
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"]}');
select throws_ok($$ select api.create_payout_batch(now()) $$, '42501', 'auth:forbidden', 'admin_finance tanpa aal2 ditolak');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
insert into t_pay select 'batch', api.create_payout_batch(now());
select is((select count from api.payout_batches where id = (select id from t_pay where k = 'batch')), 3, 'batch memuat 3 payout batch requested');
select throws_ok($$ select api.approve_payout_batch((select id from t_pay where k = 'batch')) $$, '23514', null,
                 'pembuat batch tidak bisa menyetujui sendiri (dua orang)');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f2', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select lives_ok($$ select api.approve_payout_batch((select id from t_pay where k = 'batch')) $$, 'admin_finance lain menyetujui batch');
reset role;
select is(jsonb_array_length(api.bridge_get_batch((select id from t_pay where k = 'batch')) -> 'payouts'), 3, 'bridge_get_batch: isi batch approved');
select api.bridge_attach_export((select id from t_pay where k = 'batch'), 'pii-exports/batch-1.csv',
                                jsonb_build_array(jsonb_build_object('payout_id', (select id from t_pay where k = 'b3'), 'reason', 'nama_tidak_cocok')));
select is((select status::text from finance.payouts where id = (select id from t_pay where k = 'b3')), 'on_hold', 'gagal cek export → on_hold');
select is((select count from finance.payout_batches where id = (select id from t_pay where k = 'batch')), 2, 'batch: 2 payout masuk CSV');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select throws_ok($$ select api.mark_batch_paid((select id from t_pay where k = 'batch'),
                    jsonb_build_array(jsonb_build_object('payout_id', (select id from t_pay where k = 'b3'), 'status', 'paid'))) $$,
                 'P0001', 'payout_not_in_export', 'mark paid hanya untuk payout di CSV');
select lives_ok($$ select api.mark_batch_paid((select id from t_pay where k = 'batch'), jsonb_build_array(
                   jsonb_build_object('payout_id', (select id from t_pay where k = 'b1'), 'status', 'paid', 'bank_ref', 'TRX-1'),
                   jsonb_build_object('payout_id', (select id from t_pay where k = 'b2'), 'status', 'failed'))) $$,
                'mark_batch_paid paid + failed');
reset role;
select is((select string_agg(status::text, ',' order by amount) from finance.payouts
           where id in (select id from t_pay where k in ('b1', 'b2'))), 'returned,paid', 'S-05: paid / failed → returned');
select is((select status from finance.payout_batches where id = (select id from t_pay where k = 'batch')), 'paid', 'batch paid');
-- 1.000.000 + 2.502 − 200.000 − 100.000 (b3) − 100.000 (i2) − 100.000 (i3), b2 & i1 kembali
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available'), 502502::numeric, 'payout gagal: saldo kembali ke Tersedia');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'withdrawn'), 490000::numeric, 'Ditarik = b1 + b3 + i2 + i3 (bersih fee)');
select is((select count(*)::int from ops.notifications where event = 'payout.paid'), 2, 'notifikasi payout sukses (instant + batch)');
select api.bridge_attach_proof('batch', (select id from t_pay where k = 'batch'), 'payout-proofs/batch-1.pdf');
select is((select status from finance.payout_batches where id = (select id from t_pay where k = 'batch')), 'closed', 'bukti transfer → batch closed');
select is((select proof_ref from finance.payouts where id = (select id from t_pay where k = 'b1')), 'payout-proofs/batch-1.pdf',
          'proof_ref tersimpan di payout paid');

-- ========== D. Fulfillment non-tunai (S-06) ==========
insert into vault.secrets (id, name, secret) values ('eeeeeeee-0000-0000-0000-00000000000f', 'webhook:gems', 'rahasia-hmac');
insert into market.reward_types (id, owner_org_id, code, name, kind, unit_label, idr_value_per_unit, fulfillment, webhook_url, webhook_secret_ref)
values ('77777777-0000-0000-0000-000000000004', '44444444-0000-0000-0000-000000000001', 'GEMS', 'Gems', 'in_game', 'Gems', 100, 'webhook',
        'https://brand.example/hook', 'eeeeeeee-0000-0000-0000-00000000000f');
select finance.post(gen_random_uuid(), jsonb_build_array(
  finance.e(finance.account('bank_clearing', null, x.rt), -x.amt, 'adjustment', 'fixture:andi-' || x.rt),
  finance.e(finance.account('user_wallet', '11111111-0000-0000-0000-00000000000a', x.rt), x.amt, 'adjustment', 'fixture:andi-' || x.rt, 'available')))
  from (values ('77777777-0000-0000-0000-000000000002'::uuid, 100), ('77777777-0000-0000-0000-000000000003'::uuid, 2),
               ('77777777-0000-0000-0000-000000000004'::uuid, 1)) x(rt, amt);
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.request_fulfillment('77777777-0000-0000-0000-000000000002', 50, '{"game_user_id":"123"}', null, 'ful-key-01') $$,
                 'P0001', 'recipient_ref_required', 'field pii (alamat) wajib lewat recipient_ref identity');
select throws_ok($$ select api.request_fulfillment('77777777-0000-0000-0000-000000000002', 50, '{"game_user_id":"123","address":"Jl. X"}',
                    gen_random_uuid(), 'ful-key-01') $$, 'P0001', 'pii_in_recipient', 'nilai field pii tidak boleh disimpan di core');
select throws_ok($$ select api.request_fulfillment('77777777-0000-0000-0000-000000000002', 50, '{}', gen_random_uuid(), 'ful-key-01') $$,
                 'P0001', 'recipient_incomplete', 'field penerima wajib (game_user_id) harus diisi');
select throws_ok($$ select api.request_fulfillment('77777777-0000-0000-0000-000000000002', 101, '{"game_user_id":"123"}', gen_random_uuid(),
                    'ful-key-01') $$, 'P0001', 'insufficient_balance', 'klaim melebihi saldo Diamonds ditolak');
select lives_ok($$ select api.request_fulfillment('77777777-0000-0000-0000-000000000002', 50, '{"game_user_id":"123"}', gen_random_uuid(),
                   'ful-key-01') $$, 'klaim Diamonds dengan recipient_ref');
select throws_ok($$ select api.request_fulfillment('77777777-0000-0000-0000-000000000003', 2, '{}', null, 'ful-key-02') $$,
                 'P0001', 'invalid:amount', 'code_pool: satu klaim = satu kode');
insert into t_pay select 'f1', (api.request_fulfillment('77777777-0000-0000-0000-000000000003', 1, '{}', null, 'ful-key-03')).id;
insert into t_pay select 'f2', (api.request_fulfillment('77777777-0000-0000-0000-000000000003', 1, '{}', null, 'ful-key-04')).id;
insert into t_pay select 'f3', (api.request_fulfillment('77777777-0000-0000-0000-000000000004', 1, '{}', null, 'ful-key-05')).id;
reset role;
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'withdrawn', '77777777-0000-0000-0000-000000000002'), 50::numeric,
          'klaim: Diamonds available → withdrawn');
select is((select count(*)::int from api.bridge_fulfillment_export('77777777-0000-0000-0000-000000000002')), 1, 'export klaim manual ke brand');
insert into finance.reward_codes (reward_type_id, code, uploaded_by) values ('77777777-0000-0000-0000-000000000003', 'VC-1', '22222222-0000-0000-0000-0000000000a1');
select is((select count(*)::int from api.worker_fulfillments_due(10)), 3, 'worker fulfill: 2 code_pool + 1 webhook jatuh tempo');
select is((select count(*)::int from api.worker_fulfillments_due(10)), 0, 'lease 5 menit: tidak diambil dua kali');
select is(api.worker_assign_code((select id from t_pay where k = 'f1')), 'VC-1', 'kode dipasang dari pool');
select is(api.worker_assign_code((select id from t_pay where k = 'f1')), 'VC-1', 'assign diulang = kode yang sama');
select api.worker_fulfillment_result((select id from t_pay where k = 'f1'), true, 'VC-1', null);
select is((select status::text from finance.fulfillments where id = (select id from t_pay where k = 'f1')), 'delivered', 'kode terkirim → delivered');
select is((select count(*)::int from ops.notifications where event = 'fulfillment.delivered'), 1, 'notifikasi reward terkirim');
select is(api.worker_assign_code((select id from t_pay where k = 'f2')), null, 'pool kode kosong → NULL');
select is((select status::text from finance.fulfillments where id = (select id from t_pay where k = 'f2')), 'on_hold', 'pool kosong → on_hold');
select ok(exists (select 1 from ops.alerts where kind = 'fulfillment.stuck' and payload ->> 'reason' = 'code_pool_empty'), 'alert pool kode kosong');
select api.worker_fulfillment_result((select id from t_pay where k = 'f3'), false, null, 'timeout') from generate_series(1, 11);
select is((select status::text from finance.fulfillments where id = (select id from t_pay where k = 'f3')), 'requested', '11 gagal: masih dicoba ulang');
select api.worker_fulfillment_result((select id from t_pay where k = 'f3'), false, null, 'timeout');
select is((select status::text || ':' || attempts from finance.fulfillments where id = (select id from t_pay where k = 'f3')), 'on_hold:12',
          'gagal ke-12 → on_hold');
select is((select count(*)::int from ops.alerts where kind = 'fulfillment.stuck'), 2, 'alert fulfillment macet');

-- ========== E. Konfirmasi invoice (F-A08) ==========
insert into market.campaigns (id, org_id, slug, title, type, platforms, start_at, submit_deadline, created_by)
values ('55555555-0000-0000-0000-0000000000a8', '44444444-0000-0000-0000-000000000001', 'k8-invoice', 'Invoice', 'clipping', '{tiktok}',
        now() + interval '1 day', now() + interval '20 days', '22222222-0000-0000-0000-0000000000a1');
update market.campaigns set status = 'in_review' where id = '55555555-0000-0000-0000-0000000000a8';
insert into finance.reward_pools (id, campaign_id, reward_type_id, total, max_per_clip) values
  ('66666666-0000-0000-0000-0000000000a8', '55555555-0000-0000-0000-0000000000a8', '77777777-0000-0000-0000-000000000001', 10000000, 1000000),
  ('66666666-0000-0000-0000-0000000000d8', '55555555-0000-0000-0000-0000000000a8', '77777777-0000-0000-0000-000000000002', 50000, 2000);
insert into finance.invoices (id, number, org_id, campaign_id, kind, subtotal, mgmt_fee, admin_fee, tax, total) values
  ('dddddddd-0000-0000-0000-0000000000c1', 'INV-C1', '44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8',
   'campaign', 25000000, 3750000, 1250000, 550000, 30550000),
  ('dddddddd-0000-0000-0000-0000000000c2', 'INV-C2', '44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8',
   'campaign', 25000000, 3750000, 1250000, 550000, 30550000);
insert into finance.invoices (id, number, org_id, campaign_id, kind, subtotal, mgmt_fee, admin_fee, service_fee, tax, total, pin_until) values
  ('dddddddd-0000-0000-0000-0000000000c3', 'INV-P1', '44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8',
   'pinned', 0, 0, 0, 1000000, 110000, 1110000, now() + interval '14 days');
insert into finance.invoices (id, number, org_id, campaign_id, kind, subtotal, mgmt_fee, admin_fee, tax, total, pool_topups) values
  ('dddddddd-0000-0000-0000-0000000000c4', 'INV-T1', '44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8',
   'topup', 2000000, 300000, 100000, 44000, 2444000, '[{"pool_id":"66666666-0000-0000-0000-0000000000a8","amount":2000000}]');
insert into finance.invoices (id, number, org_id, kind, subtotal, mgmt_fee, admin_fee, service_fee, total, status, payment_channel, payment_ref,
                              paid_amount, paid_at, confirmed_by) values
  ('dddddddd-0000-0000-0000-0000000000c5', 'INV-M1', '44444444-0000-0000-0000-000000000001', 'managed_service', 0, 0, 0, 2500000, 2500000,
   'paid', 'transfer', 'REF-USED', 2500000, now(), '33333333-0000-0000-0000-0000000000f1');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"]}');
select throws_ok($$ select api.confirm_invoice_payment('dddddddd-0000-0000-0000-0000000000c1', 30550000, now(), 'REF-C1', 'transfer') $$,
                 '42501', 'auth:forbidden', 'konfirmasi invoice butuh aal2');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select throws_ok($$ select api.confirm_invoice_payment('dddddddd-0000-0000-0000-0000000000c1', 30000000, now(), 'REF-C1', 'transfer') $$,
                 'P0001', 'amount_mismatch', 'nominal beda dari total invoice ditolak');
select throws_ok($$ select api.confirm_invoice_payment('dddddddd-0000-0000-0000-0000000000c1', 30550000, now(), 'REF-USED', 'transfer') $$,
                 '23505', 'duplicate_payment_ref', 'referensi pembayaran yang sudah dipakai ditolak');
select lives_ok($$ select api.confirm_invoice_payment('dddddddd-0000-0000-0000-0000000000c1', 30550000, now(), 'REF-C1', 'transfer') $$,
                'invoice campaign dikonfirmasi');
select lives_ok($$ select api.confirm_invoice_payment('dddddddd-0000-0000-0000-0000000000c1', 30550000, now(), 'REF-C1', 'transfer') $$,
                'konfirmasi yang sama diulang = no-op');
select throws_ok($$ select api.confirm_invoice_payment('dddddddd-0000-0000-0000-0000000000c2', 30550000, now(), 'REF-C2', 'transfer') $$,
                 'P0001', 'campaign_already_funded', 'invoice campaign kedua untuk campaign yang sama ditolak');
select lives_ok($$ select api.confirm_invoice_payment('dddddddd-0000-0000-0000-0000000000c3', 1110000, now(), 'REF-P1', 'qris') $$, 'invoice pinned');
select lives_ok($$ select api.confirm_invoice_payment('dddddddd-0000-0000-0000-0000000000c4', 2444000, now(), 'REF-T1', 'transfer') $$, 'invoice top-up');
reset role;
select is((select status || ':' || payment_ref || ':' || paid_amount from finance.invoices where id = 'dddddddd-0000-0000-0000-0000000000c1'),
          'paid:REF-C1:30550000.00', 'invoice paid dengan referensi & nominal');
select is((select jsonb_object_agg(a.owner_type || ':' || rt.code, s.amount) from
            (select e.account_id, sum(e.amount) as amount from finance.ledger_entries e
              where e.ref_type = 'invoice_payment' and e.ref_id = 'dddddddd-0000-0000-0000-0000000000c1' group by e.account_id) s
            join finance.ledger_accounts a on a.id = s.account_id join market.reward_types rt on rt.id = a.reward_type_id),
          '{"bank_clearing:IDR":-30550000, "campaign_pool:IDR":10000000, "platform_revenue:IDR":5000000, "tax_payable:IDR":550000,
            "org_credit:IDR":15000000, "bank_clearing:DIAMOND":-50000, "campaign_pool:DIAMOND":50000}'::jsonb,
          'jurnal invoice: kas → pool Rupiah, fee → revenue, pajak → tax_payable, nilai Rp pool non-tunai → org_credit; stok Diamonds → pool');
select is((select count(*)::int from finance.ledger_entries where ref_id = 'dddddddd-0000-0000-0000-0000000000c1'), 7, 'replay tidak menjurnal ulang');
select is((select pinned_until from market.campaigns where id = '55555555-0000-0000-0000-0000000000a8'),
          (select pin_until from finance.invoices where id = 'dddddddd-0000-0000-0000-0000000000c3'), 'invoice pinned lunas → pinned_until diset');
select is((select total from finance.reward_pools where id = '66666666-0000-0000-0000-0000000000a8'), 12000000::numeric, 'top-up menambah total pool');
select is(pg_temp.acct('campaign_pool', '66666666-0000-0000-0000-0000000000a8'), 12000000::numeric, 'top-up mengisi saldo akun pool');
select ok((select count(*) >= 2 from ops.notifications where event = 'invoice.paid' and user_id = '22222222-0000-0000-0000-0000000000c1'),
          'brand_finance dinotifikasi pembayaran diterima');

-- ========== F. Sisa budget: rollover vs refund (D-09) ==========
update market.campaigns set status = 'cancelled' where id = '55555555-0000-0000-0000-0000000000a8';
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1');
select throws_ok($$ select api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8', 'rollover',
                    3000000, 'roll-key-1') $$, '42501', 'auth:forbidden', 'refund/rollover butuh aal2');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select throws_ok($$ select api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a1', 'refund',
                    1000, 'refund-live-1') $$, 'P0001', 'invalid_state:live', 'campaign yang masih berjalan tidak bisa direfund');
insert into t_pay select 'roll', api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8', 'rollover',
                                                    3000000, 'roll-key-1');
select is(api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8', 'rollover', 3000000, 'roll-key-1'),
          (select id from t_pay where k = 'roll'), 'rollover diulang dengan key sama = transaksi yang sama');
insert into t_pay select 'refund', api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8', 'refund',
                                                      5000000, 'refund-key-1');
select throws_ok($$ select api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8', 'refund',
                    4000001, 'refund-key-2') $$, 'P0001', 'insufficient_balance', 'refund melebihi sisa budget ditolak');
reset role;
select is(pg_temp.acct('campaign_pool', '66666666-0000-0000-0000-0000000000a8'), 4000000::numeric, 'sisa pool berkurang rollover + refund');
select is((select sum(e.amount) from finance.ledger_entries e where e.ref_type = 'rollover'), 0::numeric, 'jurnal rollover seimbang');
select is((select e.amount from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
           where e.ref_type = 'rollover' and a.owner_type = 'org_credit'), 3000000::numeric, 'rollover → org_credit');
select is((select status || ':' || transfer_fee from finance.org_refunds where id = (select id from t_pay where k = 'refund')), 'requested:2500.00',
          'refund → E-35 requested dengan biaya transfer');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select lives_ok($$ select api.approve_refund((select id from t_pay where k = 'refund')) $$, 'admin_finance menyetujui refund');
reset role;
select api.bridge_attach_proof('refund', (select id from t_pay where k = 'refund'), 'payout-proofs/refund-1.pdf');
select is((select status from finance.org_refunds where id = (select id from t_pay where k = 'refund')), 'paid', 'bukti transfer → refund paid');
select is((select jsonb_object_agg(a.owner_type, e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
           where e.ref_type = 'refund' and e.ref_id = (select id from t_pay where k = 'refund') || ':paid'),
          '{"org_credit":-5000000, "bank_clearing":4997500, "platform_revenue":2500}'::jsonb, 'refund dibayar: kas keluar dikurangi biaya transfer');

-- ========== G. Bonus referral (F-C16) ==========
update tracking.submissions set locked_at = now() - interval '8 days' where id = (select v::uuid from t_ids where k = 's7b');
select finance.release_earnings();
insert into market.referrals (referred_id, referrer_id, code, qualified_at, bonus_until) values
  ('11111111-0000-0000-0000-00000000000b', '11111111-0000-0000-0000-00000000000f', 'fani0001', now() - interval '100 days', now() - interval '10 days');
select finance.accrue_referral_bonus();
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000d', 'available'), 125::numeric,
          'bonus 5% dari earning andi yang Tersedia (Rp2.502 → Rp125, dibulatkan ke bawah)');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000f', 'available'), 0::numeric, 'lewat bonus_until → tanpa bonus');
select is((select sum(e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
           where e.ref_type = 'referral_bonus' and a.owner_type = 'platform_revenue'), -125::numeric, 'bonus dibayar dari akun platform');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available'), 502502::numeric, 'earning teman tidak dipotong');
select finance.accrue_referral_bonus();
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000d', 'available'), 125::numeric, 'job referral diulang = no-op');

-- ========== H. Fraud queue (F-A06) ==========
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000a9', 'k9-fraud', 0);
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000a9', '66666666-0000-0000-0000-0000000000a9', 1000000, 1000000);
select pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a9', '66666666-0000-0000-0000-0000000000a9', 'per_1k_views', '{"rate":1000}');
insert into t_ids select 's9b', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a9', '11111111-0000-0000-0000-00000000000b', 'v9b');
insert into t_ids select 's9e', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a9', '11111111-0000-0000-0000-00000000000e', 'v9e');
select pg_temp.snap((select v::uuid from t_ids where k = 's9b'), 5000);
select pg_temp.snap((select v::uuid from t_ids where k = 's9e'), 3000);
insert into t_pay select 'fl1', trust.raise_flag('submission', (select v::uuid from t_ids where k = 's9b'), 'FR-01', 50, '{}');
insert into t_pay select 'fl2', trust.raise_flag('submission', (select v::uuid from t_ids where k = 's9b'), 'FR-02', 70, '{}');
insert into t_pay select 'fl3', trust.raise_flag('profile', '11111111-0000-0000-0000-00000000000b', 'FR-05', 60, '{}');
insert into t_pay select 'fl4', trust.raise_flag('profile', '11111111-0000-0000-0000-00000000000e', 'FR-04', 90, '{}');
select is(trust.raise_flag('submission', (select v::uuid from t_ids where k = 's9b'), 'FR-01', 50, '{}'), null,
          'satu flag terbuka per target + sinyal');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select throws_ok($$ select api.resolve_fraud_flag((select id from t_pay where k = 'fl1'), 'hold', null) $$, '42501', 'auth:forbidden',
                 'fraud queue hanya admin_moderator');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
select api.resolve_fraud_flag((select id from t_pay where k = 'fl1'), 'hold', 'cek manual');
select is((select f.status || ':' || s.status from api.fraud_flags f, api.submissions s
           where f.id = (select id from t_pay where k = 'fl1') and s.id = (select v::uuid from t_ids where k = 's9b')), 'held:flagged',
          'hold: flag held, earning submisi ditahan (flagged)');
select api.resolve_fraud_flag((select id from t_pay where k = 'fl1'), 'dismiss', 'organik');
select is((select status::text from api.submissions where id = (select v::uuid from t_ids where k = 's9b')), 'flagged',
          'dismiss satu flag: masih flagged selama ada flag lain');
select api.resolve_fraud_flag((select id from t_pay where k = 'fl2'), 'reverse', 'views dibeli');
reset role;
select is((select status::text from tracking.submissions where id = (select v::uuid from t_ids where k = 's9b')), 'forfeited', 'reverse → submisi hangus');
select is((select sum(ce.amount) from finance.clip_earnings ce where ce.submission_id = (select v::uuid from t_ids where k = 's9b')), 0::numeric,
          'reverse: earning pending submisi kembali ke pool');
select is((select allocated from finance.reward_pools where id = '66666666-0000-0000-0000-0000000000a9'), 3000::numeric, 'pool menerima Rp5.000 kembali');
select is((select delta from trust.score_events where ref_id = (select id::text from t_pay where k = 'fl2')), -10::smallint, 'reverse menurunkan Trust Score');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
select api.resolve_fraud_flag((select id from t_pay where k = 'fl3'), 'suspend', 'device sama');
select api.resolve_fraud_flag((select id from t_pay where k = 'fl4'), 'ban', 'NIK ganda');
reset role;
select ok((select status = 'suspended' and suspended_until > now() + interval '29 days' from market.profiles
           where id = '11111111-0000-0000-0000-00000000000b'), 'suspend 30 hari');
select is((select status::text from market.profiles where id = '11111111-0000-0000-0000-00000000000e'), 'banned', 'ban → profil banned');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000e', 'pending'), 0::numeric, 'ban → semua pending hangus (kembali ke pool)');
select ok(exists (select 1 from net.http_request_queue q where q.body ->> 'action' = 'ban_user'
                  and q.body ->> 'user_id' = '11111111-0000-0000-0000-00000000000e'), 'ban → bridge identity admin-auth');
select is((select count(*)::int from ops.audit_logs where action = 'fraud_flag.resolve'), 5, 'semua sanksi tercatat di audit log');

select * from finish();
rollback;
