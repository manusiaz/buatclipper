-- Mesin uang & RPC service core: accrual §10.5, release, payout/batch/instant, invoice, refund, referral, fraud queue, lifecycle,
-- RPC worker/bridge (service_role), alert & overview admin. Jalankan: supabase test db --workdir db/core
begin;
-- Fixture tes tidak bergantung seed.sql; di-rollback di akhir.
-- Stack lokal bisa berisi data uji manual: semua tabel domain + antrean pgmq dikosongkan dulu.
do $$ begin execute (select 'truncate ' || string_agg(format('%I.%I', schemaname, tablename), ', ') || ' cascade'
  from pg_tables where schemaname in ('market', 'tracking', 'finance', 'trust', 'ops')
     or (schemaname = 'pgmq' and tablename like 'q\_%')); end $$;
select no_plan();

insert into ops.settings (key, value) values
  ('auth.identity_issuer', '"https://auth.contoh.id/auth/v1"'),
  ('public.finance.min_withdraw_idr', '100000'),
  ('public.finance.instant_min_trust', '70'),
  ('public.flags.instant_withdraw', 'false'),
  ('public.market.max_accounts_per_platform', '3'),
  ('public.finance.hold_days', '7'),
  ('finance.settlement_threshold_pct', '5'),
  ('finance.settlement_wait_hours', '6'),
  ('finance.referral_bonus_pct', '5'),
  ('finance.referral_bonus_days', '90'),
  ('public.finance.refund_transfer_fee_idr', '2500'),
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
grant all on t_pay, t_ids to authenticated, service_role;
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
insert into t_ids select 'rf_old', pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a5', '66666666-0000-0000-0000-0000000000a5', 'flat_per_post',
  '{"amount":10000}', now() - interval '30 days', now() - interval '1 day');
insert into t_ids select 'rf_new', pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a5', '66666666-0000-0000-0000-0000000000a5', 'flat_per_post',
  '{"amount":15000}', now() - interval '1 day');
update market.rate_rules set lineage_id = (select v::uuid from t_ids where k = 'rf_old') where id = (select v::uuid from t_ids where k = 'rf_new');
insert into t_ids select 'rf_ind', pg_temp.mk_rule('55555555-0000-0000-0000-0000000000a5', '66666666-0000-0000-0000-0000000000a5', 'flat_per_post',
  '{"amount":3000}');
insert into t_ids select 's5', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000a5', '11111111-0000-0000-0000-00000000000c', 'v5',
                                              now() - interval '5 days');
select pg_temp.snap((select v::uuid from t_ids where k = 's5'), 2000, now() - interval '2 days');
select pg_temp.snap((select v::uuid from t_ids where k = 's5'), 5000, now() - interval '1 hour');
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's5'), (select v::uuid from t_ids where k = 'r_old')), 4000::numeric,
          'raise_rate: snapshot sebelum effective_to memakai rate lama');
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's5'), (select v::uuid from t_ids where k = 'r_new')), 9000::numeric,
          'raise_rate: Δ sesudahnya memakai rate baru');
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's5'), (select v::uuid from t_ids where k = 'rf_old'))
          + pg_temp.rule_amt((select v::uuid from t_ids where k = 's5'), (select v::uuid from t_ids where k = 'rf_new')), 10000::numeric,
          'regresi R5: flat yang sudah dibayar tidak dibayar lagi setelah raise_rate (rule baru = versi rule yang sama)');
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's5'), (select v::uuid from t_ids where k = 'rf_ind')), 3000::numeric,
          'regresi R6: flat lain di pool yang sama (bukan revisi) tetap dibayar');

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
select is((select payload - 'submission_id' from ops.notifications where event = 'earning.available'
           and user_id = '11111111-0000-0000-0000-00000000000a'),
          '{"campaign_id":"55555555-0000-0000-0000-0000000000a7","campaign_title":"Campaign k7-release","org_id":"44444444-0000-0000-0000-000000000001",
            "amounts":[{"amount":2502,"reward_type":"IDR","unit_label":"Rp"}]}'::jsonb, 'notifikasi earning tersedia: judul campaign + nominal + satuan');
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
-- Regresi 2026-10-19: trigger deferred jalan saat COMMIT sebagai authenticated (rollback pgTAP menyembunyikannya).
select lives_ok($$ set constraints all immediate $$, 'trigger saldo seimbang (deferred) lolos sebagai authenticated');
set constraints all deferred;
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
select ok(exists (select 1 from net.http_request_queue q where convert_from(q.body, 'UTF8')::jsonb ->> 'action' = 'disburse'
                  and convert_from(q.body, 'UTF8')::jsonb ->> 'payout_id' = (select id::text from t_pay where k = 'i1')), 'instant: bridge disburse dipanggil (alur 11)');
select is(api.bridge_get_payout((select id from t_pay where k = 'i1')) ->> 'net_amount', '95000.00', 'bridge_get_payout: transfer = amount − fee');
select api.bridge_mark_instant((select id from t_pay where k = 'i1'), 'failed', null, 'rekening tidak valid');
select is((select status::text from finance.payouts where id = (select id from t_pay where k = 'i1')), 'returned', 'instant gagal → returned');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available'), 802502::numeric, 'instant gagal: dana + biaya kembali ke Tersedia');
select is(pg_temp.acct('platform_revenue', null) - (-1000000), 0::numeric, 'instant gagal: biaya dikembalikan');
select ok(exists (select 1 from ops.alerts where kind = 'payout.failed' and payload ->> 'error' = 'rekening tidak valid'), 'alert payout gagal');
select is((select count(*)::int from net.http_request_queue q where convert_from(q.body, 'UTF8')::jsonb ->> 'action' = 'notify_admins'
            and convert_from(q.body, 'UTF8')::jsonb ->> 'kind' = 'payout.failed'), 1,
          'regresi G-12: alert payout gagal → email admin lewat bridge (F-X01 admin)');
select ops.raise_alert('payout.failed', 'warning', '{"payout_id":"x"}');
select is((select count(*)::int from net.http_request_queue q where convert_from(q.body, 'UTF8')::jsonb ->> 'action' = 'notify_admins'
            and convert_from(q.body, 'UTF8')::jsonb ->> 'kind' = 'payout.failed'), 1, 'regresi C20-1: alert beruntun selagi email masih dikirim (transaksi yang sama) tidak mengirim email lagi');
update ops.alerts set notify_requested_at = now() - interval '16 minutes' where kind = 'payout.failed';
select is(ops.notify_alerts('payout.failed'), 1, 'regresi C19-2: email yang belum terkirim diulang job alert-notify (≥ 15 menit)');
select api.bridge_alert_notified((select max(id) from ops.alerts where kind = 'payout.failed'));
update ops.alerts set notify_requested_at = now() - interval '16 minutes' where kind = 'payout.failed';
select ops.raise_alert('payout.failed', 'warning', '{"payout_id":"y"}');
select is((select count(*)::int from net.http_request_queue q where convert_from(q.body, 'UTF8')::jsonb ->> 'action' = 'notify_admins'
            and convert_from(q.body, 'UTF8')::jsonb ->> 'kind' = 'payout.failed'), 2, 'alert beruntun dalam 1 jam setelah email terkirim tidak mengirim email lagi');
insert into ops.alerts (kind, severity, payload) values ('reconcile.orphans', 'critical', '{}');
select is(ops.notify_alerts('reconcile.orphans'), 1, 'regresi C19-2: job alert-notify mengulang alert yang emailnya belum terkirim');
select is(ops.notify_alerts('payout.failed'), 0, 'job alert-notify tidak mengulang jenis yang sudah terkirim dalam 1 jam');
select ops.raise_alert('payout.on_hold', 'warning', '{}');
select is((select count(*)::int from net.http_request_queue q where convert_from(q.body, 'UTF8')::jsonb ->> 'action' = 'notify_admins'
            and convert_from(q.body, 'UTF8')::jsonb ->> 'kind' = 'payout.on_hold'), 0, 'alert di luar daftar F-X01 admin tidak dikirim email');
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
-- Regresi review 2026-10-19: payout di batch approved tidak bisa dibatalkan (sudah/akan masuk CSV transfer).
select throws_ok($$ select api.cancel_payout((select id from t_pay where k = 'b1'), 'batal') $$, 'P0001', 'batch_locked',
                 'payout requested di batch approved terkunci');
reset role;
select is(jsonb_array_length(api.bridge_get_batch((select id from t_pay where k = 'batch')) -> 'payouts'), 3, 'bridge_get_batch: isi batch approved');
select is((select jsonb_agg(x - 'id' - 'user_id' order by x ->> 'amount') from jsonb_array_elements(api.bridge_get_batch((select id from t_pay where k = 'batch')) -> 'payouts') x),
          '[{"method_id":"aaaaaaaa-0000-0000-0000-0000000000b1","amount":100000.00,"fee":0.00,"blocked":null},
            {"method_id":"aaaaaaaa-0000-0000-0000-0000000000b1","amount":150000.00,"fee":0.00,"blocked":null},
            {"method_id":"aaaaaaaa-0000-0000-0000-0000000000b1","amount":200000.00,"fee":0.00,"blocked":null}]'::jsonb,
          'bridge_get_batch: amount bruto + fee (transfer = amount − fee), blocked kosong untuk clipper aktif');
-- Regresi review 2026-10-19 (R3): CSV yang tidak cocok dengan isi batch saat ini tidak diserahkan.
select throws_ok($$ select api.bridge_attach_export((select id from t_pay where k = 'batch'), 'pii-exports/batch-1.csv',
                      jsonb_build_array(jsonb_build_object('payout_id', (select id from t_pay where k = 'b3'), 'reason', 'nama_tidak_cocok')),
                      array[(select id from t_pay where k = 'b1')]) $$, 'P0001', 'export_stale',
                 'CSV tanpa payout requested yang tidak ditahan → export_stale');
select throws_ok($$ select api.bridge_attach_export((select id from t_pay where k = 'batch'), 'pii-exports/batch-1.csv', '[]'::jsonb,
                      array[(select id from t_pay where k = 'b1'), (select id from t_pay where k = 'b2'), (select id from t_pay where k = 'b3'),
                            gen_random_uuid()]) $$, 'P0001', 'export_stale', 'CSV berisi payout di luar batch → export_stale');
select api.bridge_attach_export((select id from t_pay where k = 'batch'), 'pii-exports/batch-1.csv',
                                jsonb_build_array(jsonb_build_object('payout_id', (select id from t_pay where k = 'b3'), 'reason', 'nama_tidak_cocok')),
                                array[(select id from t_pay where k = 'b1'), (select id from t_pay where k = 'b2')]);
select is((select status::text from finance.payouts where id = (select id from t_pay where k = 'b3')), 'on_hold', 'gagal cek export → on_hold');
select is((select count from finance.payout_batches where id = (select id from t_pay where k = 'batch')), 2, 'batch: 2 payout masuk CSV');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select throws_ok($$ select api.mark_batch_paid((select id from t_pay where k = 'batch'),
                    jsonb_build_array(jsonb_build_object('payout_id', (select id from t_pay where k = 'b3'), 'status', 'paid'))) $$,
                 'P0001', 'payout_not_in_export', 'mark paid hanya untuk payout di CSV');
select throws_ok($$ select api.mark_batch_paid((select id from t_pay where k = 'batch'),
                    jsonb_build_array(jsonb_build_object('payout_id', (select id from t_pay where k = 'b1'), 'status', 'paid', 'bank_ref', ' '))) $$,
                 'P0001', 'invalid:bank_ref', 'regresi C20-3: payout paid wajib referensi mutasi bank');
select lives_ok($$ select api.mark_batch_paid((select id from t_pay where k = 'batch'), jsonb_build_array(
                   jsonb_build_object('payout_id', (select id from t_pay where k = 'b1'), 'status', 'paid', 'bank_ref', 'TRX-1'),
                   jsonb_build_object('payout_id', (select id from t_pay where k = 'b2'), 'status', 'failed', 'reason', 'rekening ditutup'))) $$,
                'mark_batch_paid paid + failed');
reset role;
select is((select string_agg(status::text, ',' order by amount) from finance.payouts
           where id in (select id from t_pay where k in ('b1', 'b2'))), 'returned,paid', 'S-05: paid / failed → returned');
select is((select status from finance.payout_batches where id = (select id from t_pay where k = 'batch')), 'paid', 'batch paid');
select is((select last_error from finance.payouts where id = (select id from t_pay where k = 'b2')), 'rekening ditutup',
          'alasan gagal tersimpan (dibaca admin finance)');
-- 1.000.000 + 2.502 − 200.000 − 100.000 (b3) − 100.000 (i2) − 100.000 (i3), b2 & i1 kembali
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available'), 502502::numeric, 'payout gagal: saldo kembali ke Tersedia');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'withdrawn'), 490000::numeric, 'Ditarik = b1 + b3 + i2 + i3 (bersih fee)');
select is((select count(*)::int from ops.notifications where event = 'payout.paid'), 2, 'notifikasi payout sukses (instant + batch)');
select api.bridge_attach_proof('batch', (select id from t_pay where k = 'batch'), 'payout-proofs/batch-1.pdf');
select is((select status from finance.payout_batches where id = (select id from t_pay where k = 'batch')), 'closed', 'bukti transfer → batch closed');
select is((select proof_ref from finance.payouts where id = (select id from t_pay where k = 'b1')), 'payout-proofs/batch-1.pdf',
          'proof_ref tersimpan di payout paid');
select ok((select payload ->> 'unit_label' = 'Rp' and payload ->> 'reward_type' = 'IDR' and payload ? 'payout_id' and payload ->> 'amount' = '150000'
           from ops.notifications where event = 'payout.failed' and payload ->> 'payout_id' = (select id::text from t_pay where k = 'b2')),
          'payload payout.failed: payout_id + nominal + satuan');
-- Penyedia mengirim REVERSED setelah paid (S-05 paid → failed): dana kembali, idempoten
select api.bridge_mark_instant((select id from t_pay where k = 'i2'), 'failed', 'PRV-1', 'REVERSED');
select api.bridge_mark_instant((select id from t_pay where k = 'i2'), 'failed', 'PRV-1', 'REVERSED');
select is((select status::text from finance.payouts where id = (select id from t_pay where k = 'i2')), 'returned', 'instant paid lalu REVERSED → returned');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available'), 602502::numeric, 'REVERSED: dana + biaya kembali ke Tersedia (sekali)');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'withdrawn'), 395000::numeric, 'REVERSED: Ditarik berkurang Rp95.000');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"]}');
select throws_ok($$ select api.cancel_payout((select id from t_pay where k = 'b3'), 'nama tidak cocok') $$, '42501', 'auth:forbidden',
                 'batal payout butuh admin_finance aal2');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select throws_ok($$ select api.cancel_payout((select id from t_pay where k = 'i3'), 'salah') $$, 'P0001', 'invalid_state:requested',
                 'instant yang mungkin sedang diproses penyedia tidak bisa dibatalkan');
select lives_ok($$ select api.cancel_payout((select id from t_pay where k = 'b3'), 'nama rekening tidak cocok KYC') $$,
                'payout on_hold dibatalkan admin_finance');
select lives_ok($$ select api.cancel_payout((select id from t_pay where k = 'b3'), 'ulang') $$, 'batal payout idempoten');
reset role;
select is((select status::text from finance.payouts where id = (select id from t_pay where k = 'b3')), 'cancelled', 'S-05 on_hold → cancelled');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available'), 702502::numeric, 'payout dibatalkan: dana kembali ke Tersedia (sekali)');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'withdrawn'), 295000::numeric, 'payout dibatalkan: Ditarik berkurang');
select ok((select payload ->> 'amount' = '100000' and payload ->> 'unit_label' = 'Rp' and payload ->> 'payout_id' = (select id::text from t_pay where k = 'b3')
           from ops.notifications where event = 'payout.cancelled'), 'notifikasi payout.cancelled dengan nominal');

-- ========== D. Fulfillment non-tunai (S-06) ==========
-- Vault asli mengenkripsi lewat fungsi milik supabase_admin: secret dibuat lewat API resmi, bukan INSERT langsung.
insert into t_ids select 'gems_secret', vault.create_secret('rahasia-hmac', 'webhook:gems')::text;
insert into market.reward_types (id, owner_org_id, code, name, kind, unit_label, idr_value_per_unit, fulfillment, webhook_url, webhook_secret_ref)
values ('77777777-0000-0000-0000-000000000004', '44444444-0000-0000-0000-000000000001', 'GEMS', 'Gems', 'in_game', 'Gems', 100, 'webhook',
        'https://brand.example/hook', (select v::uuid from t_ids where k = 'gems_secret'));
select finance.post(gen_random_uuid(), jsonb_build_array(
  finance.e(finance.account('bank_clearing', null, x.rt), -x.amt, 'adjustment', 'fixture:andi-' || x.rt),
  finance.e(finance.account('user_wallet', '11111111-0000-0000-0000-00000000000a', x.rt), x.amt, 'adjustment', 'fixture:andi-' || x.rt, 'available')))
  from (values ('77777777-0000-0000-0000-000000000002'::uuid, 100), ('77777777-0000-0000-0000-000000000003'::uuid, 2),
               ('77777777-0000-0000-0000-000000000004'::uuid, 1)) x(rt, amt);
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.request_fulfillment('77777777-0000-0000-0000-000000000002', 50, '{"game_user_id":"123"}', null, 'ful-key-01') $$,
                 'P0001', 'recipient_ref_required', 'field pii (alamat) wajib lewat recipient_ref identity');
select throws_ok($$ select api.request_fulfillment('77777777-0000-0000-0000-000000000002', 50, '{"game_user_id":"123"}', gen_random_uuid(),
                    'ful-key-01') $$, 'P0001', 'consent_required:share_with_brand',
                 'regresi AC-1 (C2.4): consent share_with_brand dicabut/tidak ada → reward ber-PII tidak bisa diklaim');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a', '{"consent_ok":{"share_with_brand":true}}');
select throws_ok($$ select api.request_fulfillment('77777777-0000-0000-0000-000000000002', 50, '{"game_user_id":"123","address":"Jl. X"}',
                    gen_random_uuid(), 'ful-key-01') $$, 'P0001', 'pii_in_recipient', 'nilai field pii tidak boleh disimpan di core');
select throws_ok($$ select api.request_fulfillment('77777777-0000-0000-0000-000000000002', 50, '{}', gen_random_uuid(), 'ful-key-01') $$,
                 'P0001', 'recipient_incomplete', 'field penerima wajib (game_user_id) harus diisi');
select throws_ok($$ select api.request_fulfillment('77777777-0000-0000-0000-000000000002', 101, '{"game_user_id":"123"}', gen_random_uuid(),
                    'ful-key-01') $$, 'P0001', 'insufficient_balance', 'klaim melebihi saldo Diamonds ditolak');
insert into t_pay select 'fd', (api.request_fulfillment('77777777-0000-0000-0000-000000000002', 50, '{"game_user_id":"123"}', gen_random_uuid(),
                                                         'ful-key-01')).id;
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
-- Regresi review R4: worker mati sebelum mencatat hasil → lease kedaluwarsa diambil ulang = hasil kiriman lama tidak pasti.
update finance.fulfillments set leased_until = now() - interval '1 minute', next_retry_at = now() - interval '1 minute'
 where id = (select id from t_pay where k = 'f3');
select is((select count(*)::int from api.worker_fulfillments_due(10)), 1, 'lease kedaluwarsa diambil ulang');
select ok((select delivery_uncertain from finance.fulfillments where id = (select id from t_pay where k = 'f3')),
          'lease kedaluwarsa tanpa hasil → kiriman lama tidak pasti');
-- Regresi review 2026-10-19: klaim yang sedang dikirim worker tidak bisa dibatalkan (reward terkirim + saldo kembali).
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select throws_ok($$ select api.cancel_fulfillment((select id from t_pay where k = 'f3'), 'batal') $$, 'P0001', 'delivery_in_flight',
                 'webhook sedang dikirim: batal ditolak sampai hasil tercatat');
reset role;
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
-- Regresi review 2026-10-19 (R3): timeout ≠ pasti gagal → refund butuh konfirmasi brand; serah-terima CSV manual mengunci klaim.
select ok((select delivery_uncertain from finance.fulfillments where id = (select id from t_pay where k = 'f3')), 'timeout → hasil tidak pasti');
-- Regresi audit 2 AA-4 (C6.2/J-A5): webhook macet bisa dikirim ulang admin setelah brand memperbaiki endpoint
select is((select count(*)::int from api.worker_fulfillments_due(10) d where d.id = (select id from t_pay where k = 'f3')), 0,
          'webhook macet tidak dicoba lagi otomatis');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select throws_ok($$ select api.retry_fulfillment((select id from t_pay where k = 'f2')) $$, 'P0001', 'invalid_state:on_hold',
                 'pool kode kosong tidak "dikirim ulang" (unggah kode)');
select lives_ok($$ select api.retry_fulfillment((select id from t_pay where k = 'f3')) $$, 'regresi AA-4: admin mengirim ulang webhook macet');
reset role;
select is((select count(*)::int from api.worker_fulfillments_due(10) d where d.id = (select id from t_pay where k = 'f3')), 1,
          'worker mengambil webhook yang dikirim ulang');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select throws_ok($$ select api.mark_fulfillment_delivered((select id from t_pay where k = 'f3'), 'BRAND-OK') $$, 'P0001', 'delivery_in_flight',
                 'regresi R27-1: webhook yang sedang dikirim worker tidak bisa ditandai terkirim manual (cegah kirim dua kali)');
reset role;
update finance.fulfillments set leased_until = null where id = (select id from t_pay where k = 'f3');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select throws_ok($$ select api.mark_fulfillment_delivered((select id from t_pay where k = 'f3'), 'BRAND-OK') $$, 'P0001', 'invalid_state:retrying',
                 'kirim ulang terjadwal: tunggu hasilnya dulu');
reset role;
select api.worker_fulfillment_result((select id from t_pay where k = 'f3'), false, null, 'timeout') from generate_series(1, 12);
select is((select status::text || ':' || attempts || ':' || (next_retry_at is null)::text from finance.fulfillments
            where id = (select id from t_pay where k = 'f3')), 'on_hold:12:true', 'gagal 12× lagi → berhenti lagi (tidak berulang tanpa batas)');
insert into finance.fulfillments (id, user_id, reward_type_id, amount, recipient, idempotency_key) values
  ('99999999-0000-0000-0000-0000000000e1', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000002', 5,
   '{"game_user_id":"123"}', 'ful-export-test');
select finance.post(gen_random_uuid(), jsonb_build_array(  -- setara request_fulfillment: Tersedia → Ditarik
  finance.e(finance.account('user_wallet', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000002'), -5,
            'fulfillment', '99999999-0000-0000-0000-0000000000e1', 'available'),
  finance.e(finance.account('user_wallet', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000002'), 5,
            'fulfillment', '99999999-0000-0000-0000-0000000000e1', 'withdrawn')));
select api.bridge_attach_fulfillment_export('77777777-0000-0000-0000-000000000002', 'pii-exports/recipients/x.csv',
                                            array['99999999-0000-0000-0000-0000000000e1'::uuid]);
select is((select status::text || ':' || export_ref from finance.fulfillments where id = '99999999-0000-0000-0000-0000000000e1'),
          'processing:pii-exports/recipients/x.csv', 'CSV diserahkan → klaim processing + export_ref');
select lives_ok($$ select api.bridge_attach_fulfillment_export('77777777-0000-0000-0000-000000000002', 'pii-exports/recipients/x.csv',
                     array['99999999-0000-0000-0000-0000000000e1'::uuid]) $$, 'serah-terima berkas yang sama diulang (respons hilang) = no-op');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
reset role;
select ok(api.bridge_fulfillment_export_accepted('77777777-0000-0000-0000-000000000002', 'pii-exports/recipients/x.csv')
          and not api.bridge_fulfillment_export_accepted('77777777-0000-0000-0000-000000000002', 'pii-exports/recipients/z.csv'),
          'regresi R6: core hanya mengakui CSV yang benar-benar diserahkan');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select is((select file_ref || ':' || pending from api.fulfillment_exports where reward_type_id = '77777777-0000-0000-0000-000000000002'),
          'pii-exports/recipients/x.csv:1', 'regresi R5: admin melihat CSV yang sudah diserahkan (unduh ulang)');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a', '{}');
select is((select count(*)::int from api.fulfillment_exports), 0, 'daftar export tidak terbaca clipper');
reset role;
select ok(not exists (select 1 from api.bridge_fulfillment_export('77777777-0000-0000-0000-000000000002')
                       where id = '99999999-0000-0000-0000-0000000000e1'), 'klaim yang sudah diserahkan tidak terekspor ulang');
select throws_ok($$ select api.bridge_attach_fulfillment_export('77777777-0000-0000-0000-000000000002', 'pii-exports/recipients/y.csv',
                      array['99999999-0000-0000-0000-0000000000e1'::uuid]) $$, 'P0001', 'export_stale', 'serah-terima ulang klaim yang sama ditolak');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select throws_ok($$ select api.cancel_fulfillment((select id from t_pay where k = 'f3'), 'batal') $$, 'P0001', 'delivery_unconfirmed',
                 'webhook tidak pasti: refund butuh konfirmasi brand');
select throws_ok($$ select api.cancel_fulfillment('99999999-0000-0000-0000-0000000000e1', 'batal') $$, 'P0001', 'delivery_unconfirmed',
                 'CSV sudah di brand: refund butuh konfirmasi brand');
select lives_ok($$ select api.cancel_fulfillment((select id from t_pay where k = 'f3'), 'brand konfirmasi tidak terkirim', true) $$,
                'refund setelah konfirmasi brand');
select lives_ok($$ select api.cancel_fulfillment('99999999-0000-0000-0000-0000000000e1', 'brand belum kirim', true) $$,
                'refund klaim manual setelah konfirmasi brand');
reset role;
select is((select string_agg(status::text, ',' order by id) from finance.fulfillments
            where id in ((select id from t_pay where k = 'f3'), '99999999-0000-0000-0000-0000000000e1')),
          (select string_agg(x, ',' order by i) from (values (1, case when (select id from t_pay where k = 'f3') < '99999999-0000-0000-0000-0000000000e1'::uuid
                                                              then 'cancelled' else 'returned' end),
                                                        (2, case when (select id from t_pay where k = 'f3') < '99999999-0000-0000-0000-0000000000e1'::uuid
                                                              then 'returned' else 'cancelled' end)) v(i, x)),
          'on_hold → cancelled, processing → returned');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select throws_ok($$ select api.cancel_fulfillment((select id from t_pay where k = 'f1'), 'salah') $$, 'P0001', 'invalid_state:delivered',
                 'reward yang sudah terkirim tidak bisa dibatalkan');
-- F-A10 manual: tandai terkirim (manual_export saja) + upload kode oleh admin
reset role;
insert into finance.fulfillments (id, user_id, reward_type_id, amount, recipient, idempotency_key) values
  ('99999999-0000-0000-0000-0000000000fd', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000002', 10,
   '{"game_user_id":"123"}', 'ful-manual-test');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select lives_ok($$ select api.mark_fulfillment_delivered('99999999-0000-0000-0000-0000000000fd', 'RESI-123') $$, 'admin menandai reward manual terkirim');
select lives_ok($$ select api.mark_fulfillment_delivered('99999999-0000-0000-0000-0000000000fd', 'RESI-123') $$, 'tandai ulang = no-op');
select throws_ok($$ select api.mark_fulfillment_delivered((select id from t_pay where k = 'f2'), 'X') $$, 'P0001', 'invalid:fulfillment',
                 'reward code_pool tidak ditandai manual');
reset role;
insert into finance.fulfillments (id, user_id, reward_type_id, amount, idempotency_key) values
  ('99999999-0000-0000-0000-0000000000fe', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000004', 1, 'ful-webhook-stuck');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select throws_ok($$ select api.mark_fulfillment_delivered('99999999-0000-0000-0000-0000000000fe', 'BRAND-OK') $$, 'P0001', 'invalid:fulfillment',
                 'webhook yang masih dicoba otomatis tidak ditandai manual');
reset role;
update finance.fulfillments set status = 'on_hold', attempts = 12 where id = '99999999-0000-0000-0000-0000000000fe';
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select lives_ok($$ select api.mark_fulfillment_delivered('99999999-0000-0000-0000-0000000000fe', 'BRAND-OK') $$,
                'regresi AA-4: webhook macet ditandai terkirim setelah brand konfirmasi');
reset role;
select is((select status::text from finance.fulfillments where id = '99999999-0000-0000-0000-0000000000fe'), 'delivered', 'webhook macet → delivered');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select is(api.upload_reward_codes('77777777-0000-0000-0000-000000000003', array['VC-ADM']), 1, 'admin_ops mengunggah kode');
-- F-A07: override Trust Score, suspend, unsuspend
select throws_ok($$ select api.manage_user('11111111-0000-0000-0000-00000000000a', 'trust_override', '{"delta":-5}') $$, 'P0001', 'invalid:reason',
                 'aksi admin atas user wajib alasan');
select lives_ok($$ select api.manage_user('11111111-0000-0000-0000-00000000000a', 'trust_override', '{"delta":-5,"note":"cek manual"}') $$,
                'override Trust Score');
select lives_ok($$ select api.manage_user('11111111-0000-0000-0000-00000000000a', 'suspend', '{"days":3,"reason":"spam"}') $$, 'suspend 3 hari');
select lives_ok($$ select api.manage_user('11111111-0000-0000-0000-00000000000a', 'unsuspend', '{"note":"banding diterima"}') $$, 'unsuspend');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000b');
select throws_ok($$ select api.manage_user('11111111-0000-0000-0000-00000000000a', 'suspend', '{"days":3,"reason":"x"}') $$, '42501', 'auth:forbidden',
                 'clipper tidak bisa mengelola user');
reset role;
select is((select status::text || ':' || delivered_ref from finance.fulfillments where id = '99999999-0000-0000-0000-0000000000fd'), 'delivered:RESI-123',
          'reward manual delivered dengan resi');
select is((select trust_score from market.profiles where id = '11111111-0000-0000-0000-00000000000a'),
          (select least(100, greatest(0, 50 + sum(delta)))::smallint from trust.score_events where user_id = '11111111-0000-0000-0000-00000000000a'),
          'override: skor dihitung ulang langsung dengan rumus job');
select is((select status::text from market.profiles where id = '11111111-0000-0000-0000-00000000000a'), 'active', 'unsuspend → active');
select is((select array_agg(action order by id) from ops.audit_logs where action like 'user.%'), array['user.trust_override', 'user.suspend', 'user.unsuspend'],
          'aksi admin atas user tercatat audit log');
select ok(exists (select 1 from ops.notifications where event = 'account.suspended' and user_id = '11111111-0000-0000-0000-00000000000a'),
          'clipper dikabari suspend');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select lives_ok($$ select api.cancel_fulfillment((select id from t_pay where k = 'f2'), 'stok kode habis') $$, 'klaim on_hold dibatalkan');
select lives_ok($$ select api.cancel_fulfillment((select id from t_pay where k = 'fd'), 'ID game tidak valid') $$, 'klaim requested dibatalkan');
select lives_ok($$ select api.cancel_fulfillment((select id from t_pay where k = 'fd'), 'ulang') $$, 'batal klaim idempoten');
reset role;
select is((select string_agg(status::text, ',' order by amount) from finance.fulfillments where id in (select id from t_pay where k in ('f2', 'fd'))),
          'cancelled,cancelled', 'S-06 → cancelled');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available', '77777777-0000-0000-0000-000000000002'), 100::numeric,
          'klaim Diamonds batal: saldo kembali ke Tersedia');
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available', '77777777-0000-0000-0000-000000000003'), 1::numeric,
          'klaim voucher batal: saldo kembali ke Tersedia (sekali)');
select ok(exists (select 1 from ops.notifications where event = 'fulfillment.cancelled' and payload ->> 'unit_label' = 'Diamonds'
                  and payload ->> 'amount' = '50'), 'notifikasi fulfillment.cancelled dengan nominal & satuan');
-- Regresi review R11: klaim voucher yang tertahan karena pool kosong lanjut sendiri setelah kode diunggah ulang (VC-ADM bebas).
insert into finance.fulfillments (id, user_id, reward_type_id, amount, recipient, idempotency_key) values
  ('99999999-0000-0000-0000-0000000000e2', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000003', 1, '{}',
   'ful-restock-test');
select finance.post(gen_random_uuid(), jsonb_build_array(
  finance.e(finance.account('user_wallet', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000003'), -1,
            'fulfillment', '99999999-0000-0000-0000-0000000000e2', 'available'),
  finance.e(finance.account('user_wallet', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000003'), 1,
            'fulfillment', '99999999-0000-0000-0000-0000000000e2', 'withdrawn')));
update finance.fulfillments set status = 'on_hold', last_error = 'code_pool_empty', next_retry_at = now() - interval '1 minute'
 where id = '99999999-0000-0000-0000-0000000000e2';
select ok(exists (select 1 from api.worker_fulfillments_due(10) d where d.id = '99999999-0000-0000-0000-0000000000e2'),
          'regresi R11: klaim on_hold pool kosong diambil worker lagi setelah restock');
select is(api.worker_assign_code('99999999-0000-0000-0000-0000000000e2'), 'VC-ADM', 'kode hasil restock dipasang');
select api.worker_fulfillment_result('99999999-0000-0000-0000-0000000000e2', true, 'VC-ADM', null);
select is((select status::text from finance.fulfillments where id = '99999999-0000-0000-0000-0000000000e2'), 'delivered',
          'on_hold → processing → delivered');
-- Regresi review R12: kode sudah terpasang (worker mati sebelum hasil tercatat) dan pool habis lagi → tetap diambil ulang.
insert into finance.fulfillments (id, user_id, reward_type_id, amount, recipient, idempotency_key) values
  ('99999999-0000-0000-0000-0000000000e3', '11111111-0000-0000-0000-00000000000a', '77777777-0000-0000-0000-000000000003', 1, '{}',
   'ful-restock-crash');
update finance.fulfillments set status = 'on_hold', last_error = 'code_pool_empty', next_retry_at = now() - interval '1 minute'
 where id = '99999999-0000-0000-0000-0000000000e3';
insert into finance.reward_codes (reward_type_id, code, uploaded_by, fulfillment_id, assigned_at)
values ('77777777-0000-0000-0000-000000000003', 'VC-E3', '22222222-0000-0000-0000-0000000000a1', '99999999-0000-0000-0000-0000000000e3', now());
select ok(exists (select 1 from api.worker_fulfillments_due(10) d where d.id = '99999999-0000-0000-0000-0000000000e3'),
          'regresi R12: klaim yang kodenya sudah terpasang diambil ulang walau pool kosong');
select is(api.worker_assign_code('99999999-0000-0000-0000-0000000000e3'), 'VC-E3', 'assign ulang = kode yang sama');

-- ========== E. Invoice (§5.2) & konfirmasi pembayaran (F-A08) ==========
insert into market.campaigns (id, org_id, slug, title, type, platforms, start_at, submit_deadline, created_by)
values ('55555555-0000-0000-0000-0000000000a8', '44444444-0000-0000-0000-000000000001', 'k8-invoice', 'Invoice', 'clipping', '{tiktok}',
        now() + interval '1 day', now() + interval '20 days', '22222222-0000-0000-0000-0000000000a1');
update market.campaigns set status = 'in_review' where id = '55555555-0000-0000-0000-0000000000a8';
insert into finance.reward_pools (id, campaign_id, reward_type_id, total, max_per_clip) values
  ('66666666-0000-0000-0000-0000000000a8', '55555555-0000-0000-0000-0000000000a8', '77777777-0000-0000-0000-000000000001', 10000000, 1000000),
  ('66666666-0000-0000-0000-0000000000d8', '55555555-0000-0000-0000-0000000000a8', '77777777-0000-0000-0000-000000000002', 50000, 2000);
insert into ops.settings (key, value) values ('public.billing.tax_pct', '11');
insert into t_pay select 'inv_c1', (finance.issue_invoice('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8',
                                                          'campaign', finance.campaign_budget_idr('55555555-0000-0000-0000-0000000000a8'))).id;
select is((select array[subtotal, mgmt_fee, admin_fee, service_fee, tax, total] from finance.invoices where id = (select id from t_pay where k = 'inv_c1')),
          array[10000000, 3750000, 1250000, 0, 550000, 15550000]::numeric[],
          '§5.2 stok non-tunai: subtotal = pool Rupiah saja; fee 15% + 5% atas Rp10 jt + nilai deklarasi 50.000 Diamonds × Rp300');
insert into t_pay select 'inv_t1', (finance.issue_invoice('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8',
  'topup', 999, 0, null, '[{"pool_id":"66666666-0000-0000-0000-0000000000a8","amount":2000000},
                           {"pool_id":"66666666-0000-0000-0000-0000000000d8","amount":1000}]')).id;
select is((select array[subtotal, mgmt_fee, admin_fee, service_fee, tax, total] from finance.invoices where id = (select id from t_pay where k = 'inv_t1')),
          array[2000000, 345000, 115000, 0, 50600, 2510600]::numeric[],
          'top-up campuran: tagihan tunai Rp2 jt; fee atas Rp2 jt + 1.000 Diamonds × Rp300');
insert into finance.invoices (id, number, org_id, campaign_id, kind, subtotal, mgmt_fee, admin_fee, tax, total) values
  ('dddddddd-0000-0000-0000-0000000000c2', 'INV-C2', '44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8',
   'campaign', 10000000, 3750000, 1250000, 550000, 15550000);
insert into finance.invoices (id, number, org_id, campaign_id, kind, subtotal, mgmt_fee, admin_fee, service_fee, tax, total, pin_until) values
  ('dddddddd-0000-0000-0000-0000000000c3', 'INV-P1', '44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8',
   'pinned', 0, 0, 0, 1000000, 110000, 1110000, now() + interval '14 days');
insert into finance.invoices (id, number, org_id, campaign_id, kind, subtotal, mgmt_fee, admin_fee, tax, total, pool_topups) values
  ('dddddddd-0000-0000-0000-0000000000c6', 'INV-T9', '44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8',
   'topup', 2000, 0, 0, 0, 2000, '[{"pool_id":"66666666-0000-0000-0000-0000000000a8","amount":1000}]');
insert into finance.invoices (id, number, org_id, kind, subtotal, mgmt_fee, admin_fee, service_fee, total, status, payment_channel, payment_ref,
                              paid_amount, paid_at, confirmed_by) values
  ('dddddddd-0000-0000-0000-0000000000c5', 'INV-M1', '44444444-0000-0000-0000-000000000001', 'managed_service', 0, 0, 0, 2500000, 2500000,
   'paid', 'transfer', 'REF-USED', 2500000, now(), '33333333-0000-0000-0000-0000000000f1');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"]}');
select throws_ok($$ select api.confirm_invoice_payment((select id from t_pay where k = 'inv_c1'), 15550000, now(), 'REF-C1', 'transfer') $$,
                 '42501', 'auth:forbidden', 'konfirmasi invoice butuh aal2');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select throws_ok($$ select api.confirm_invoice_payment((select id from t_pay where k = 'inv_c1'), 15000000, now(), 'REF-C1', 'transfer') $$,
                 'P0001', 'amount_mismatch', 'nominal beda dari total invoice ditolak');
select throws_ok($$ select api.confirm_invoice_payment((select id from t_pay where k = 'inv_c1'), 15550000, now(), 'REF-USED', 'transfer') $$,
                 '23505', 'duplicate_payment_ref', 'referensi pembayaran yang sudah dipakai ditolak');
select lives_ok($$ select api.confirm_invoice_payment((select id from t_pay where k = 'inv_c1'), 15550000, now(), 'REF-C1', 'transfer') $$,
                'invoice campaign dikonfirmasi');
select lives_ok($$ select api.confirm_invoice_payment((select id from t_pay where k = 'inv_c1'), 15550000, now(), 'REF-C1', 'transfer') $$,
                'konfirmasi yang sama diulang = no-op');
select throws_ok($$ select api.confirm_invoice_payment('dddddddd-0000-0000-0000-0000000000c2', 15550000, now(), 'REF-C2', 'transfer') $$,
                 'P0001', 'campaign_already_funded', 'invoice campaign kedua untuk campaign yang sama ditolak');
select lives_ok($$ select api.confirm_invoice_payment('dddddddd-0000-0000-0000-0000000000c3', 1110000, now(), 'REF-P1', 'qris') $$, 'invoice pinned');
select lives_ok($$ select api.confirm_invoice_payment((select id from t_pay where k = 'inv_t1'), 2510600, now(), 'REF-T1', 'transfer') $$,
                'invoice top-up');
select throws_ok($$ select api.confirm_invoice_payment('dddddddd-0000-0000-0000-0000000000c6', 2000, now(), 'REF-T9', 'transfer') $$,
                 'P0001', 'invoice_pool_mismatch', 'subtotal ≠ dana pool Rupiah → ditolak (tidak diparkir di org_credit)');
reset role;
select is((select status || ':' || payment_ref || ':' || paid_amount from finance.invoices where id = (select id from t_pay where k = 'inv_c1')),
          'paid:REF-C1:15550000.00', 'invoice paid dengan referensi & nominal');
select is((select jsonb_object_agg(a.owner_type || ':' || rt.code, s.amount) from
            (select e.account_id, sum(e.amount) as amount from finance.ledger_entries e
              where e.ref_type = 'invoice_payment' and e.ref_id = (select id::text from t_pay where k = 'inv_c1') group by e.account_id) s
            join finance.ledger_accounts a on a.id = s.account_id join market.reward_types rt on rt.id = a.reward_type_id),
          '{"bank_clearing:IDR":-15550000, "campaign_pool:IDR":10000000, "platform_revenue:IDR":5000000, "tax_payable:IDR":550000,
            "bank_clearing:DIAMOND":-50000, "campaign_pool:DIAMOND":50000}'::jsonb,
          'jurnal invoice: kas → pool Rupiah, fee → revenue, pajak → tax_payable; stok Diamonds brand → pool Diamonds');
select is((select count(*)::int from finance.ledger_entries where ref_id = (select id::text from t_pay where k = 'inv_c1')), 6,
          'replay tidak menjurnal ulang');
select is((select count(*)::int from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
           where e.ref_type = 'invoice_payment' and a.owner_type = 'org_credit'), 0, 'tidak ada dana invoice yang diparkir di org_credit');
select is((select pinned_until from market.campaigns where id = '55555555-0000-0000-0000-0000000000a8'),
          (select pin_until from finance.invoices where id = 'dddddddd-0000-0000-0000-0000000000c3'), 'invoice pinned lunas → pinned_until diset');
select is((select array[total, pg_temp.acct('campaign_pool', id)] from finance.reward_pools where id = '66666666-0000-0000-0000-0000000000a8'),
          array[12000000, 12000000]::numeric[], 'top-up menambah total & saldo pool Rupiah');
select is((select array[total, pg_temp.acct('campaign_pool', id, reward_type_id)] from finance.reward_pools
            where id = '66666666-0000-0000-0000-0000000000d8'), array[51000, 51000]::numeric[], 'top-up stok Diamonds menambah pool Diamonds');
select ok((select count(*) >= 2 from ops.notifications where event = 'invoice.paid' and user_id = '22222222-0000-0000-0000-0000000000c1'),
          'brand_finance dinotifikasi pembayaran diterima');
select ok(exists (select 1 from ops.notifications where event = 'invoice.paid' and payload ->> 'campaign_title' = 'Invoice'
                  and payload ->> 'org_id' = '44444444-0000-0000-0000-000000000001' and payload ->> 'amount' = '15550000'),
          'payload invoice.paid: judul campaign, org, nominal');

-- ========== F. Batal sebelum live → refund penuh (D-09) ==========
update market.campaigns set status = 'cancelled' where id = '55555555-0000-0000-0000-0000000000a8';
insert into t_pay select 'cancel_refund', id from finance.org_refunds where idempotency_key = 'cancel:55555555-0000-0000-0000-0000000000a8';
select is((select status || ':' || amount || ':' || transfer_fee from finance.org_refunds where id = (select id from t_pay where k = 'cancel_refund')),
          'requested:19170600.00:0.00', 'batal sebelum live → refund E-35 = semua yang dibayar (budget + fee + pajak), tanpa potongan');
select is((select jsonb_object_agg(a.owner_type || ':' || rt.code, e.amount) from finance.ledger_entries e
            join finance.ledger_accounts a on a.id = e.account_id join market.reward_types rt on rt.id = a.reward_type_id
           where e.ref_type = 'refund' and e.ref_id = (select id::text from t_pay where k = 'cancel_refund')),
          '{"campaign_pool:IDR":-12000000, "platform_revenue:IDR":-6460000, "tax_payable:IDR":-710600, "org_credit:IDR":19170600,
            "campaign_pool:DIAMOND":-51000, "bank_clearing:DIAMOND":51000}'::jsonb,
          'jurnal batal: pool Rupiah dikuras + fee & pajak dibalik → org_credit; stok Diamonds kembali ke brand');
select is(finance.refund_cancelled_campaign('55555555-0000-0000-0000-0000000000a8'), (select id from t_pay where k = 'cancel_refund'),
          'refund batal idempoten');
select is((select count(*)::int from finance.ledger_entries where ref_type = 'refund' and ref_id = (select id::text from t_pay where k = 'cancel_refund')),
          6, 'idempoten: tidak ada jurnal kedua');
select is((select string_agg(status, ',' order by number) from finance.invoices where id in ('dddddddd-0000-0000-0000-0000000000c2',
                                                                                              'dddddddd-0000-0000-0000-0000000000c6')),
          'void,void', 'invoice yang belum lunas di-void');
select ok(exists (select 1 from ops.notifications where event = 'refund.requested' and user_id = '22222222-0000-0000-0000-0000000000c1'
                  and payload ->> 'campaign_title' = 'Invoice' and payload ->> 'amount' = '19170600'), 'brand dikabari refund diajukan');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select throws_ok($$ select api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a8', 'refund',
                    10000, 'refund-after-cancel') $$, 'P0001', 'insufficient_balance', 'pool sudah dikuras: tidak bisa refund dua kali');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f2', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select throws_ok($$ select api.approve_refund((select id from t_pay where k = 'cancel_refund')) $$, 'P0001', 'refund_dest_missing',
                 'regresi AB-6: refund tanpa rekening tujuan tidak bisa disetujui (finance tidak tahu harus transfer ke mana)');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select throws_ok($$ select api.set_refund_dest((select id from t_pay where k = 'cancel_refund'),
                                               '{"bank":"BCA","account_no":"1234567890","account_name":"Budi Santoso"}') $$,
                 'P0001', 'refund_name_mismatch', 'rekening refund badan usaha harus atas nama legal org (bukan rekening pribadi)');
reset role;
update market.organizations set status = 'pending_verification', verified_at = null, verified_by = null
 where id = '44444444-0000-0000-0000-000000000001';
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select throws_ok($$ select api.set_refund_dest((select id from t_pay where k = 'cancel_refund'),
                                               '{"bank":"BCA","account_no":"1234567890","account_name":"PT Studio Satu"}') $$,
                 'P0001', 'org_unverified', 'regresi R25-2: nama legal yang belum (ulang) diverifikasi bukan dasar rekening refund');
reset role;
update market.organizations set status = 'verified', verified_at = now(), verified_by = '33333333-0000-0000-0000-0000000000f1'
 where id = '44444444-0000-0000-0000-000000000001';
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select lives_ok($$ select api.set_refund_dest((select id from t_pay where k = 'cancel_refund'),
                                              '{"bank":"BCA","account_no":"123-456-7890","account_name":"PT. STUDIO SATU"}') $$,
                'regresi AB-6: brand billing mengisi rekening perusahaan untuk refund batal');
reset role;
select is((select dest_bank || ':' || dest_account || ':' || dest_name from finance.org_refunds where id = (select id from t_pay where k = 'cancel_refund')),
          'BCA:1234567890:PT. STUDIO SATU', 'rekening tujuan tersimpan (nomor dinormalkan)');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f2', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select lives_ok($$ select api.approve_refund((select id from t_pay where k = 'cancel_refund')) $$,
                'admin_finance lain menyetujui refund batal (pembatal = pengaju, dua orang)');
select api.set_bank_ref('refund', (select id from t_pay where k = 'cancel_refund'), 'TRF-REFUND-BATAL');
reset role;
select api.bridge_attach_proof('refund', (select id from t_pay where k = 'cancel_refund'), 'payout-proofs/refund-cancel.pdf');
select is((select jsonb_object_agg(a.owner_type, e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
           where e.ref_type = 'refund' and e.ref_id = (select id from t_pay where k = 'cancel_refund') || ':paid'),
          '{"org_credit":-19170600, "bank_clearing":19170600}'::jsonb, 'refund batal dibayar penuh ke brand');

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
select is(pg_temp.bal('11111111-0000-0000-0000-00000000000a', 'available'), 702502::numeric, 'earning teman tidak dipotong');
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
reset role;
insert into t_pay select 'fl5', trust.raise_flag('payout', (select id from t_pay where k = 'i3'), 'FR-07', 50, '{}');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
select api.resolve_fraud_flag((select id from t_pay where k = 'fl5'), 'hold', 'cek');
reset role;
select is((select status::text from finance.payouts where id = (select id from t_pay where k = 'i3')), 'requested',
          'regresi R4: instant yang sedang dikirim ke penyedia tidak ikut ditahan (tidak bisa dibatalkan + refund)');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
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
select ok(exists (select 1 from ops.notifications where event = 'account.banned' and user_id = '11111111-0000-0000-0000-00000000000e'),
          'ban → notifikasi account.banned');
select ok(exists (select 1 from net.http_request_queue q where convert_from(q.body, 'UTF8')::jsonb ->> 'action' = 'ban_user'
                  and convert_from(q.body, 'UTF8')::jsonb ->> 'user_id' = '11111111-0000-0000-0000-00000000000e'), 'ban → bridge identity admin-auth');
select is((select count(*)::int from ops.audit_logs where action = 'fraud_flag.resolve'), 6, 'semua sanksi tercatat di audit log');
-- Regresi audit 2 AA-8 (§12 sanksi bertingkat, "bisa dibanding sekali"): peringatan + catatan sanksi + banding sekali
select is((select string_agg(kind, ',' order by created_at, kind) from trust.sanctions where user_id = '11111111-0000-0000-0000-00000000000b'),
          'hold,reverse,suspend', 'setiap sanksi fraud queue tercatat per clipper');
insert into t_pay select 'fl6', trust.raise_flag('profile', '11111111-0000-0000-0000-00000000000a', 'FR-05', 30, '{}');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
select lives_ok($$ select api.resolve_fraud_flag((select id from t_pay where k = 'fl6'), 'warn', 'perangkat dipakai bersama') $$,
                'regresi AA-8: sanksi peringatan (tingkat pertama)');
reset role;
select ok(exists (select 1 from ops.notifications where event = 'account.warned' and user_id = '11111111-0000-0000-0000-00000000000a'),
          'peringatan → notifikasi ke clipper');
select is((select delta from trust.score_events where ref_id = (select id::text from t_pay where k = 'fl6')), -5::smallint, 'peringatan -5 Trust Score');
select is((select status::text from market.profiles where id = '11111111-0000-0000-0000-00000000000a'), 'active', 'peringatan tidak memblokir akun');
insert into t_pay select 'sanc_b', id from trust.sanctions where user_id = '11111111-0000-0000-0000-00000000000b' and kind = 'suspend';
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.appeal_sanction((select id from t_pay where k = 'sanc_b'), 'bukan saya pelakunya') $$,
                 'P0002', 'not_found:sanction', 'clipper tidak bisa membanding sanksi orang lain');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000b');
select is((select count(*)::int from api.sanctions), 3, 'clipper melihat sanksinya sendiri saja');
select lives_ok($$ select api.appeal_sanction((select id from api.sanctions where kind = 'suspend'), 'Perangkat itu milik adik saya, bukan akun ganda.') $$,
                'regresi AA-8: clipper membanding suspend');
select throws_ok($$ select api.appeal_sanction((select id from api.sanctions where kind = 'suspend'), 'banding kedua kali ya') $$, 'P0001',
                 'already_appealed', 'banding hanya sekali per sanksi');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
select lives_ok($$ select api.decide_sanction_appeal((select id from api.sanctions where kind = 'suspend' and user_id = '11111111-0000-0000-0000-00000000000b'),
                                                    'overturned', 'bukti perangkat keluarga') $$, 'moderator membatalkan sanksi lewat banding');
select throws_ok($$ select api.decide_sanction_appeal((select id from api.sanctions where kind = 'suspend' and user_id = '11111111-0000-0000-0000-00000000000b'),
                                                     'upheld', 'ubah lagi') $$, 'P0001', 'invalid_state:appeal', 'keputusan banding final');
reset role;
select is((select status::text || ':' || coalesce(suspended_until::text, '-') from market.profiles where id = '11111111-0000-0000-0000-00000000000b'),
          'active:-', 'banding dikabulkan → suspend dicabut');
select is((select delta from trust.score_events where reason = 'appeal_overturned' and user_id = '11111111-0000-0000-0000-00000000000b'), 20::smallint,
          'penalti Trust Score suspend dikembalikan');
select ok(exists (select 1 from ops.notifications where event = 'sanction.appeal_decided' and user_id = '11111111-0000-0000-0000-00000000000b'
                  and payload ->> 'decision' = 'overturned'), 'clipper dikabari hasil banding');
-- fixture bagian berikut mengandalkan budi masih disuspend
update market.profiles set status = 'suspended', suspended_until = now() + interval '30 days' where id = '11111111-0000-0000-0000-00000000000b';

-- ========== I. worker_create_submission (core/social, E-12) ==========
insert into market.campaigns (id, org_id, slug, title, type, platforms, start_at, submit_deadline, created_by, review_mode, required_hashtags,
                              min_duration_sec, max_duration_sec)
values ('55555555-0000-0000-0000-0000000000b0', '44444444-0000-0000-0000-000000000001', 'k10-submit', 'Submit', 'clipping', '{tiktok}',
        now() - interval '5 days', now() + interval '10 days', '22222222-0000-0000-0000-0000000000a1', 'auto', '{mplid}', 15, 60),
       ('55555555-0000-0000-0000-0000000000b1', '44444444-0000-0000-0000-000000000001', 'k11-brand', 'Review brand', 'clipping', '{tiktok}',
        now() - interval '5 days', now() + interval '10 days', '22222222-0000-0000-0000-0000000000a1', 'brand', '{}', null, null);
update market.campaigns set status = 'in_review' where id in ('55555555-0000-0000-0000-0000000000b0', '55555555-0000-0000-0000-0000000000b1');
update market.campaigns set status = 'scheduled' where id in ('55555555-0000-0000-0000-0000000000b0', '55555555-0000-0000-0000-0000000000b1');
update market.campaigns set status = 'live' where id in ('55555555-0000-0000-0000-0000000000b0', '55555555-0000-0000-0000-0000000000b1');
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000b0', '66666666-0000-0000-0000-0000000000b0', 1000000, 1000000);
select pg_temp.mk_rule('55555555-0000-0000-0000-0000000000b0', '66666666-0000-0000-0000-0000000000b0', 'per_1k_views', '{"rate":1000}');
insert into market.claims (id, campaign_id, user_id, expires_at, created_at) values
  ('88888888-0000-0000-0000-0000000000b0', '55555555-0000-0000-0000-0000000000b0', '11111111-0000-0000-0000-00000000000a', now() + interval '46 hours', now() - interval '2 hours'),
  ('88888888-0000-0000-0000-0000000000b1', '55555555-0000-0000-0000-0000000000b0', '11111111-0000-0000-0000-00000000000d', now() + interval '46 hours', now() - interval '2 hours'),
  ('88888888-0000-0000-0000-0000000000a3', '55555555-0000-0000-0000-0000000000a3', '11111111-0000-0000-0000-00000000000a', now() + interval '46 hours', now() - interval '2 hours'),
  ('88888888-0000-0000-0000-0000000000b2', '55555555-0000-0000-0000-0000000000b1', '11111111-0000-0000-0000-00000000000f', now() + interval '46 hours', now() - interval '2 hours');
select throws_ok($$ select api.worker_create_submission('11111111-0000-0000-0000-00000000000e', '88888888-0000-0000-0000-0000000000b0',
                    '99999999-0000-0000-0000-00000000000e', 'x', 'https://tiktok.com/x', now(), '#mplid', 30) $$, 'P0001', 'profile_inactive',
                 'submit: profil banned ditolak');
select throws_ok($$ select api.worker_create_submission('11111111-0000-0000-0000-00000000000a', gen_random_uuid(),
                    '99999999-0000-0000-0000-00000000000a', 'x', 'https://tiktok.com/x', now(), '#mplid', 30) $$, 'P0001', 'claim_not_open',
                 'submit: claim tidak ada');
select throws_ok($$ select api.worker_create_submission('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b1',
                    '99999999-0000-0000-0000-00000000000a', 'x', 'https://tiktok.com/x', now(), '#mplid', 30) $$, 'P0001', 'not_your_claim',
                 'submit: claim milik orang lain');
select throws_ok($$ select api.worker_create_submission('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000a3',
                    '99999999-0000-0000-0000-00000000000a', 'x', 'https://tiktok.com/x', now(), '#mplid', 30) $$, 'P0001', 'campaign_closed',
                 'submit: campaign sudah exhausted');
select throws_ok($$ select api.worker_create_submission('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0',
                    '99999999-0000-0000-0000-00000000000d', 'x', 'https://tiktok.com/x', now(), '#mplid', 30) $$, 'P0001', 'account_not_yours',
                 'submit: akun sosmed orang lain');
select throws_ok($$ select api.worker_create_submission('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0',
                    '99999999-0000-0000-0000-0000000000a2', 'x', 'https://instagram.com/p/x', now(), '#mplid', 30) $$, 'P0001',
                 'platform_not_allowed', 'submit: platform di luar campaign');
select throws_ok($$ select api.worker_create_submission('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0',
                    '99999999-0000-0000-0000-00000000000a', 'x', 'https://tiktok.com/x', now() - interval '3 hours', '#mplid', 30) $$, 'P0001',
                 'posted_before_claim', 'submit: diposting sebelum claim');
select throws_ok($$ select api.worker_create_submission('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0',
                    '99999999-0000-0000-0000-00000000000a', 'x', 'https://tiktok.com/x', now() - interval '1 hour', 'seru banget', 30) $$, 'P0001',
                 'missing_tags:#mplid', 'submit: hashtag wajib hilang (kode + daftar)');
select throws_ok($$ select api.worker_create_submission('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0',
                    '99999999-0000-0000-0000-00000000000a', 'x', 'https://tiktok.com/x', now() - interval '1 hour', '#mplid', 5) $$, 'P0001',
                 'duration_out_of_range', 'submit: durasi di luar batas');
insert into t_ids select 's10', api.worker_create_submission('11111111-0000-0000-0000-00000000000a', '88888888-0000-0000-0000-0000000000b0',
  '99999999-0000-0000-0000-00000000000a', 'vid-10', 'https://tiktok.com/@andi/video/10', now() - interval '1 hour', 'Mantap #MPLID', 30,
  1234567890123) ->> 'submission_id';
select is((select status::text || ':' || (next_poll_at <= now())::text from tracking.submissions where id = (select v::uuid from t_ids where k = 's10')),
          'tracking:true', 'review auto → tracking + langsung dijadwalkan poll');
select is((select status::text from market.claims where id = '88888888-0000-0000-0000-0000000000b0'), 'submitted', 'claim → submitted');
select is((select array[d.decision, coalesce(d.note, '')] from trust.review_decisions d where d.target_id = (select v::uuid from t_ids where k = 's10')),
          array['auto_approve', 'auto'], 'regresi G-17: review auto tercatat sebagai keputusan auto_approve');
select ok(exists (select 1 from trust.score_events e where e.reason = 'submission_approved' and e.ref_id = (select v from t_ids where k = 's10'))
          and exists (select 1 from ops.notifications n where n.event = 'submission.approved'
                        and n.payload ->> 'submission_id' = (select v from t_ids where k = 's10')),
          'regresi G-3/G-17: review auto menaikkan Trust Score dan mengabari clipper (submission.approved)');
select throws_ok($$ select api.worker_create_submission('11111111-0000-0000-0000-00000000000d', '88888888-0000-0000-0000-0000000000b1',
                    '99999999-0000-0000-0000-00000000000d', 'vid-10', 'https://tiktok.com/x', now() - interval '1 hour', '#mplid', 30) $$, 'P0001',
                 'already_submitted', 'submit: video sama di campaign sama');
select throws_ok($$ select api.worker_create_submission('11111111-0000-0000-0000-00000000000d', '88888888-0000-0000-0000-0000000000b1',
                    '99999999-0000-0000-0000-00000000000d', 'v1', 'https://tiktok.com/x', now() - interval '1 hour', '#mplid', 30) $$, 'P0001',
                 'reused_video', 'submit: video yang dipakai di campaign lain (allow_video_reuse mati)');
select is(api.worker_create_submission('11111111-0000-0000-0000-00000000000d', '88888888-0000-0000-0000-0000000000b1',
            '99999999-0000-0000-0000-00000000000d', 'vid-11', 'https://tiktok.com/@dedi/video/11', now() - interval '1 hour', '#mplid', null,
            1234567890120) ->> 'status',
          'in_review', 'durasi tidak diketahui + campaign berbatas durasi → in_review walau review auto');
select is(api.worker_create_submission('11111111-0000-0000-0000-00000000000f', '88888888-0000-0000-0000-0000000000b2',
            '99999999-0000-0000-0000-00000000000f', 'vid-12', 'https://tiktok.com/@fani/video/12', now() - interval '1 hour', 'halo', null,
            -1234567890123) ->> 'status',
          'in_review', 'review brand → in_review');
select is((select array[f.details -> 'duplicates' ->> 0, f.details -> 'related_user_ids' ->> 0] from trust.fraud_flags f
             join tracking.submissions s on s.id = f.target_id where f.signal = 'FR-07' and s.post_id = 'vid-11'),
          array[(select v from t_ids where k = 's10'), '11111111-0000-0000-0000-00000000000a'],
          'regresi G-5 (FR-07): cover hampir sama (jarak 2 bit) dari akun lain → flag konten duplikat');
select ok(not exists (select 1 from trust.fraud_flags f join tracking.submissions s on s.id = f.target_id
                       where f.signal = 'FR-07' and s.post_id in ('vid-10', 'vid-12')),
          'cover berbeda / submisi pertama tidak di-flag FR-07');
select is((select count(*)::int from ops.notifications where event = 'submission.pending_review' and user_id = '22222222-0000-0000-0000-0000000000a1'),
          1, 'review brand: org dinotifikasi submisi menunggu review');

-- ========== J. worker_record_snapshot (track-worker, §11) ==========
select is((select jsonb_object_keys from jsonb_object_keys(api.worker_submission_context((select v::uuid from t_ids where k = 's10'))) limit 1)
          is not null, true, 'worker_submission_context terbaca');
select is(api.worker_submission_context((select v::uuid from t_ids where k = 's10')) #>> '{campaign,required_hashtags,0}', 'mplid',
          'context memuat brief untuk cek caption');
create temp table t_rec on commit drop as
  select api.worker_record_snapshot((select v::uuid from t_ids where k = 's10'), 2000, 100, 5, 1, '#mplid mantap', '{"api":"tiktok"}',
                                    '{"reach":1500}') as r;
select is((select r - 'snapshot_id' from t_rec), jsonb_build_object('flagged', false, 'next_poll_at', now() + interval '4 hours', 'locked', false),
          'snapshot pertama: umur < 72 jam → poll lagi 4 jam');
select is((select raw from tracking.view_snapshots where id = (select (r ->> 'snapshot_id')::bigint from t_rec)),
          '{"api":"tiktok","extra":{"reach":1500}}'::jsonb, 'p_extra tersimpan di raw.extra');
select is((select last_snapshot_at is not null from tracking.submissions where id = (select v::uuid from t_ids where k = 's10'))
          and api.worker_submission_context((select v::uuid from t_ids where k = 's10')) #>> '{submission,last_snapshot_at}' is not null, true,
          'context memuat last_snapshot_at');
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's10'),
                           (select id from market.rate_rules where campaign_id = '55555555-0000-0000-0000-0000000000b0')), 2000::numeric,
          'record_snapshot memanggil accrue_earnings');
select is((api.worker_record_snapshot((select v::uuid from t_ids where k = 's10'), 100000, 10, 0, 0, '#mplid', '{}') ->> 'flagged')::boolean, true,
          'FR-01: like rate di bawah 0,5% → flag');
select is((select status::text from tracking.submissions where id = (select v::uuid from t_ids where k = 's10')), 'tracking',
          'FR-01 hanya antre review, earning tetap jalan');
select is((api.worker_record_snapshot((select v::uuid from t_ids where k = 's10'), 101000, 2000, 0, 0, 'caption diedit', '{}') ->> 'flagged')::boolean,
          true, 'FR-06: hashtag wajib hilang dari caption → flag');
select is((select status::text from tracking.submissions where id = (select v::uuid from t_ids where k = 's10')), 'flagged', 'FR-06 → submisi flagged');
select is((select last_views::text || ':' || (last_views <> counted_views)::text from api.submissions
            where id = (select v::uuid from t_ids where k = 's10')), '101000:true',
          'regresi AC-3 (F-C07): Tugas Saya membaca views snapshot terakhir walau earning tertahan flag (counted_views berbeda)');
select ok(exists (select 1 from trust.fraud_flags where target_id = (select v::uuid from t_ids where k = 's10') and signal = 'FR-06'
                  and details -> 'missing' ? '#mplid'), 'flag FR-06 mencatat tag yang hilang');
select is(pg_temp.rule_amt((select v::uuid from t_ids where k = 's10'),
                           (select id from market.rate_rules where campaign_id = '55555555-0000-0000-0000-0000000000b0')), 100000::numeric,
          'snapshot saat flagged tidak menambah earning');
select is((api.worker_record_snapshot((select v::uuid from t_ids where k = 's5'), 6000, null, null, null, null, null) ->> 'next_poll_at')::timestamptz,
          now() + interval '24 hours', 'umur posting 5 hari → poll tiap 24 jam');
select is(api.worker_record_snapshot((select v::uuid from t_ids where k = 's7'), 9999, null, null, null, null, null) ->> 'snapshot_id', null,
          'submisi yang sudah settled tidak dicatat (no-op)');
insert into ops.settings (key, value) values ('trust.fraud.min_avg_watch_sec', '3'), ('trust.fraud.max_skip_rate', '80'),
  ('trust.fraud.min_id_country_share', '0.5');
select is((api.worker_record_snapshot((select v::uuid from t_ids where k = 's2'), 140000, 5000, 100, 50, null, null, '{"avg_watch_time":1}')
           ->> 'flagged')::boolean, true, 'FR-09: durasi tonton rata-rata < 3 detik → flag');
select ok(exists (select 1 from trust.fraud_flags where target_id = (select v::uuid from t_ids where k = 's2') and signal = 'FR-09'), 'flag FR-09');
select is((select status::text from tracking.submissions where id = (select v::uuid from t_ids where k = 's2')), 'tracking', 'FR-09 hanya antre review');
select is((api.worker_record_snapshot((select v::uuid from t_ids where k = 's2'), 150000, 5000, 100, 50, null, null,
            '{"countries":{"ID":300,"US":900,"IN":800},"traffic_sources":{"ADVERTISING":1500}}') ->> 'flagged')::boolean, true,
          'FR-11: penonton Indonesia < 50% → flag');
select is((select status::text from tracking.submissions where id = (select v::uuid from t_ids where k = 's2')), 'flagged', 'FR-11 menahan earning');
select is((select (details ->> 'id_share')::numeric from trust.fraud_flags where target_id = (select v::uuid from t_ids where k = 's2')
           and signal = 'FR-11'), 0.15::numeric, 'FR-11 mencatat porsi penonton Indonesia');
select is(api.worker_account_token('99999999-0000-0000-0000-00000000000a') - 'token',
          '{"id":"99999999-0000-0000-0000-00000000000a","user_id":"11111111-0000-0000-0000-00000000000a","platform":"tiktok",
            "external_id":"tt-andi","handle":"@andi","status":"verified"}'::jsonb, 'worker_account_token: akun + token');
select api.worker_defer((select v::uuid from t_ids where k = 's5'), now() + interval '6 days');
select is((select next_poll_at from tracking.submissions where id = (select v::uuid from t_ids where k = 's5')), now() + interval '6 days',
          'worker_defer: poll dilewati sampai waktu yang diminta');
select api.worker_defer((select v::uuid from t_ids where k = 's5'), now() + interval '90 days');
select is((select next_poll_at from tracking.submissions where id = (select v::uuid from t_ids where k = 's5')), now() + interval '25 days',
          'worker_defer: tidak melewati akhir view window (poll final)');
-- Lock di akhir view window + FR-08
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000b2', 'k12-lock', 1000, 'auto', 1);
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000b2', '66666666-0000-0000-0000-0000000000b2', 1000000, 1000000);
select pg_temp.mk_rule('55555555-0000-0000-0000-0000000000b2', '66666666-0000-0000-0000-0000000000b2', 'per_1k_views', '{"rate":2000}');
insert into t_ids select 's12', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000b2', '11111111-0000-0000-0000-00000000000d', 'v12', now() - interval '2 days');
select pg_temp.snap((select v::uuid from t_ids where k = 's12'), 10000, now() - interval '36 hours');
select is((api.worker_submission_context((select v::uuid from t_ids where k = 's12')) ->> 'final')::boolean, true, 'view window lewat → poll final');
select is((api.worker_record_snapshot((select v::uuid from t_ids where k = 's12'), 7000, 500, 10, 5, null, null) ->> 'locked')::boolean, true,
          'snapshot final → submisi locked');
select is((select is_final from tracking.view_snapshots where submission_id = (select v::uuid from t_ids where k = 's12') order by id desc limit 1),
          true, 'snapshot final tercatat');
select is((select sum(amount) from finance.clip_earnings where submission_id = (select v::uuid from t_ids where k = 's12')), 14000::numeric,
          'views turun 30% saat lock → earning dikoreksi turun');
select is((select status from trust.fraud_flags where target_id = (select v::uuid from t_ids where k = 's12') and signal = 'FR-08'), 'actioned',
          'FR-08 tercatat sebagai koreksi otomatis');

-- ========== K. Post hilang, status token, akun sosmed ==========
select api.worker_post_gone((select v::uuid from t_ids where k = 's1'), 'deleted');
select is((select status::text from tracking.submissions where id = (select v::uuid from t_ids where k = 's1')), 'forfeited', 'post dihapus → forfeited');
select is((select sum(amount) from finance.clip_earnings where submission_id = (select v::uuid from t_ids where k = 's1')), 0::numeric,
          'post dihapus → earning pending hangus');
select is((select count(*)::int from ops.notifications where event = 'submission.forfeited' and user_id = '11111111-0000-0000-0000-00000000000a'), 1,
          'notifikasi submisi hangus');
select api.worker_account_status('99999999-0000-0000-0000-00000000000a', 'expired');
select api.worker_account_status('99999999-0000-0000-0000-00000000000a', 'expired');
select is((select count(*)::int from ops.notifications where event = 'social.token_expired'), 1, 'token kedaluwarsa: notifikasi sekali');
select is((select count(*)::int from tracking.submissions where social_account_id = '99999999-0000-0000-0000-00000000000a'
           and status in ('tracking', 'flagged') and next_poll_at is not null), 0, 'token kedaluwarsa: tracking di-pause');
select api.worker_account_status('99999999-0000-0000-0000-00000000000a', 'verified');
select is((select count(*)::int from tracking.submissions where social_account_id = '99999999-0000-0000-0000-00000000000a'
           and status in ('tracking', 'flagged') and next_poll_at is null), 0, 'reconnect: tracking lanjut');
insert into t_ids select 'acc_fani_ig', api.worker_upsert_social_account('11111111-0000-0000-0000-00000000000f', 'instagram', 'ig-fani', '@fani.ig', 120,
  now() - interval '3 years', jsonb_build_object('access_token', 'tok-1', 'expires_at', now() + interval '1 hour')::text);
select throws_ok($$ select api.worker_upsert_social_account('11111111-0000-0000-0000-00000000000f', 'tiktok', 'tt-andi', '@curian', 1, null, 'x') $$,
                 'P0001', 'social_taken', 'akun sosmed milik clipper lain ditolak');
select api.store_social_token('99999999-0000-0000-0000-00000000000d', jsonb_build_object('access_token', 'tok-2', 'expires_at', now() + interval '30 days')::text);
select is((select array_agg(account_id) from api.worker_accounts_to_refresh(interval '6 hours')), array[(select v::uuid from t_ids where k = 'acc_fani_ig')],
          'refresh-tokens: hanya token yang kedaluwarsa dalam 6 jam');

-- ========== L. bridge_close_account (alur 7) ==========
select is(api.bridge_close_account('11111111-0000-0000-0000-00000000000a'), '{"ok":false,"reason":"balance_remaining"}'::jsonb,
          'tutup akun ditolak selama masih ada saldo');
select is(api.bridge_close_account('11111111-0000-0000-0000-00000000000f') ->> 'ok', 'true', 'tutup akun tanpa saldo');
select ok((select status = 'closed' and username like 'deleted\_%' and display_name = 'Akun dihapus' from market.profiles
           where id = '11111111-0000-0000-0000-00000000000f'), 'profil dianonimkan + closed');
select is((select count(*)::int from tracking.social_accounts where user_id = '11111111-0000-0000-0000-00000000000f' and status <> 'disconnected'), 0,
          'akun sosmed diputus/dihapus');
select ok(not exists (select 1 from vault.secrets where name like 'social:' || (select v from t_ids where k = 'acc_fani_ig')),
          'token Vault akun sosmed dihapus');
select is((select status::text from tracking.submissions where user_id = '11111111-0000-0000-0000-00000000000f'), 'rejected',
          'submisi yang menunggu review dihentikan');

-- ========== M. Hak akses RPC service_role ==========
select is((select count(*)::int from pg_proc p where p.pronamespace = 'api'::regnamespace and p.proname ~ '^(worker|bridge)_'), 33,
          '33 RPC worker/bridge');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'api'::regnamespace and p.proname ~ '^(worker|bridge)_'
            and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))), 0,
          'authenticated/anon tidak bisa EXECUTE RPC worker/bridge');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'api'::regnamespace and p.proname ~ '^(worker|bridge)_'
            and not has_function_privilege('service_role', p.oid, 'execute')), 0, 'service_role bisa EXECUTE semua RPC worker/bridge');
select is((select count(*)::int from pg_proc p where p.pronamespace in ('finance'::regnamespace, 'ops'::regnamespace, 'trust'::regnamespace,
                                                                           'tracking'::regnamespace, 'market'::regnamespace)
            and p.proname in ('account', 'post', 'accrue_earnings', 'reverse_earning', 'release_earnings', 'accrue_referral_bonus', 'run_lifecycle',
                              'raise_flag', 'raise_alert', 'cfg', 'return_payout', 'pay_refund', 'settle_pool')
            and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('service_role', p.oid, 'execute'))), 0,
          'fungsi uang internal tidak bisa dipanggil langsung dari API');
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select throws_ok($$ select api.worker_ack('email', 1) $$, '42501', null, 'browser tidak bisa memanggil worker_ack');
select throws_ok($$ select api.bridge_close_account('11111111-0000-0000-0000-00000000000a') $$, '42501', null, 'browser tidak bisa memanggil bridge');
reset role;
select pgmq.send('tracking', jsonb_build_object('submission_id', (select v from t_ids where k = 's10')));
insert into t_ids select 'last_notif', max(id)::text from ops.notifications where event = 'social.token_expired';
set local role service_role;
select is((select count(*)::int from api.worker_dequeue('tracking', 5)), 1, 'service_role: worker_dequeue queue tracking');
select lives_ok($$ select api.worker_ack('tracking', (select max(msg_id) from api.worker_dequeue('tracking', 5))) $$, 'service_role: worker_ack');
select throws_ok($$ select * from api.worker_dequeue('rahasia', 5) $$, 'P0001', 'invalid:queue', 'hanya queue tracking & email');
select is(api.worker_notification((select v::bigint from t_ids where k = 'last_notif')) ->> 'event', 'social.token_expired', 'worker_notification');
reset role;
select api.worker_unsubscribe('11111111-0000-0000-0000-00000000000d');
select is((select email_promotions from ops.notification_prefs where user_id = '11111111-0000-0000-0000-00000000000d'), false, 'one-click unsubscribe');

-- ========== N. Lifecycle (job lifecycle, S-01 & S-03) ==========
insert into market.campaigns (id, org_id, slug, title, type, platforms, start_at, submit_deadline, created_by, review_mode) values
  ('55555555-0000-0000-0000-0000000000b3', '44444444-0000-0000-0000-000000000001', 'k13-sched', 'Terjadwal', 'clipping', '{tiktok}',
   now() - interval '1 hour', now() + interval '10 days', '22222222-0000-0000-0000-0000000000a1', 'auto'),
  ('55555555-0000-0000-0000-0000000000b4', '44444444-0000-0000-0000-000000000001', 'k14-end', 'Selesai', 'clipping', '{tiktok}',
   now() - interval '40 days', now() - interval '1 day', '22222222-0000-0000-0000-0000000000a1', 'auto'),
  ('55555555-0000-0000-0000-0000000000b5', '44444444-0000-0000-0000-000000000001', 'k15-window', 'Window', 'clipping', '{tiktok}',
   now() - interval '50 days', now() + interval '10 days', '22222222-0000-0000-0000-0000000000a1', 'auto');
update market.campaigns set status = 'in_review' where id in ('55555555-0000-0000-0000-0000000000b3', '55555555-0000-0000-0000-0000000000b4',
                                                               '55555555-0000-0000-0000-0000000000b5');
update market.campaigns set status = 'scheduled' where id in ('55555555-0000-0000-0000-0000000000b3', '55555555-0000-0000-0000-0000000000b4',
                                                               '55555555-0000-0000-0000-0000000000b5');
update market.campaigns set status = 'live' where id in ('55555555-0000-0000-0000-0000000000b4', '55555555-0000-0000-0000-0000000000b5');
update market.campaigns set min_views = 0 where id = '55555555-0000-0000-0000-0000000000b4';
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000b4', '66666666-0000-0000-0000-0000000000b4', 1000000, 1000000);
select pg_temp.mk_rule('55555555-0000-0000-0000-0000000000b4', '66666666-0000-0000-0000-0000000000b4', 'per_1k_views', '{"rate":1000}', now() - interval '40 days');
insert into t_ids select 's14', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000b4', '11111111-0000-0000-0000-00000000000d', 'v14', now() - interval '35 days');
insert into tracking.view_snapshots (submission_id, taken_at, views, is_final)
values ((select v::uuid from t_ids where k = 's14'), now() - interval '5 days', 5000, true);
insert into t_ids select 's15a', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000b5', '11111111-0000-0000-0000-00000000000d', 'v15a', now() - interval '31 days');
insert into t_ids select 's15b', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000b5', '11111111-0000-0000-0000-00000000000d', 'v15b', now() - interval '40 days');
insert into t_ids select 's15c', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000b5', '11111111-0000-0000-0000-00000000000d', 'v15c', now() - interval '1 day');
update tracking.submissions set next_poll_at = now() + interval '10 hours' where id = (select v::uuid from t_ids where k = 's15a');
update tracking.submissions set next_poll_at = null where id = (select v::uuid from t_ids where k = 's15b');
update tracking.submissions set next_poll_at = now() - interval '3 hours' where id = (select v::uuid from t_ids where k = 's15c');
update finance.payouts set created_at = now() - interval '20 minutes' where id = (select id from t_pay where k = 'i3');
select market.run_lifecycle();
select is((select count(*)::int from net.http_request_queue q where convert_from(q.body, 'UTF8')::jsonb ->> 'action' = 'disburse'
           and convert_from(q.body, 'UTF8')::jsonb ->> 'payout_id' = (select id::text from t_pay where k = 'i3')), 2, 'instant macet > 15 menit → disburse dikirim ulang');
select is((select status::text from market.campaigns where id = '55555555-0000-0000-0000-0000000000b3'), 'live', 'scheduled → live saat start_at');
select ok(exists (select 1 from ops.notifications where event = 'campaign.live' and payload ->> 'campaign_id' = '55555555-0000-0000-0000-0000000000b3'),
          'brand dinotifikasi campaign live');
select is((select array_agg(p.username order by p.username) from ops.notifications n join market.profiles p on p.id = n.user_id
            where n.event = 'campaign.new' and n.payload ->> 'campaign_id' = '55555555-0000-0000-0000-0000000000b3'), array['andi', 'dedi'],
          'campaign.new ke clipper eligible (aktif, akun verified di platform campaign; bukan suspended/banned/closed/anggota org)');
select is((select payload from ops.notifications where event = 'campaign.new' and user_id = '11111111-0000-0000-0000-00000000000a'),
          '{"campaign_id":"55555555-0000-0000-0000-0000000000b3","campaign_title":"Terjadwal","campaign_slug":"k13-sched",
            "org_name":"Studio Satu","platforms":["tiktok"]}'::jsonb, 'payload campaign.new');
select is((select count(*)::int from pgmq.q_email where message ->> 'event' = 'campaign.new' and (message ->> 'email')::boolean), 1,
          'email promosi campaign.new dilewati untuk yang unsubscribe');
-- G-9 (F-B08): brand mengumumkan ulang → hanya clipper yang baru eligible yang dikabari (tidak dobel)
insert into market.profiles (id, username, display_name) values ('11111111-0000-0000-0000-0000000000f7', 'baru_f7', 'Baru');
insert into tracking.social_accounts (user_id, platform, external_id, handle, status, followers, platform_created_at)
values ('11111111-0000-0000-0000-0000000000f7', 'tiktok', 'tt-f7', '@baru', 'verified', 5000, now() - interval '400 days');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1');
select lives_ok($$ select api.control_campaign('55555555-0000-0000-0000-0000000000b3', 'notify_eligible') $$, 'brand mengumumkan ulang campaign');
select lives_ok($$ select api.control_campaign('55555555-0000-0000-0000-0000000000b3', 'notify_eligible') $$, 'diulang aman');
reset role;
select is((select array_agg(p.username order by p.username) from ops.notifications n join market.profiles p on p.id = n.user_id
            where n.event = 'campaign.new' and n.payload ->> 'campaign_id' = '55555555-0000-0000-0000-0000000000b3'),
          array['andi', 'baru_f7', 'dedi'], 'regresi G-9: hanya clipper yang baru eligible yang dikabari, sekali');
select is((select status::text || ':' || (locked_at is not null)::text from tracking.submissions where id = (select v::uuid from t_ids where k = 's14')),
          'locked:true', 'akhir view window + snapshot final → locked');
select is((select sum(amount) from finance.clip_earnings where submission_id = (select v::uuid from t_ids where k = 's14')), 5000::numeric,
          'snapshot final dihitung sebelum lock');
select is((select status::text from market.campaigns where id = '55555555-0000-0000-0000-0000000000b4'), 'settling',
          'live → tracking (deadline lewat) → settling (tidak ada submisi aktif)');
select is((select next_poll_at from tracking.submissions where id = (select v::uuid from t_ids where k = 's15a')), now(),
          'akhir view window tanpa snapshot final → poll final diantrekan');
select is((select status::text from tracking.submissions where id = (select v::uuid from t_ids where k = 's15b')), 'locked',
          'poll final tidak datang dalam masa tenggang → locked dengan views terakhir');
select ok(exists (select 1 from ops.alerts where kind = 'tracking.final_missing'), 'alert snapshot final hilang');
select ok(exists (select 1 from ops.alerts where kind = 'tracking.lag' and (payload ->> 'overdue')::int >= 1), 'alert job tracking terlambat > 2 jam');
update tracking.submissions set locked_at = now() - interval '8 days' where id = (select v::uuid from t_ids where k = 's14');
select finance.release_earnings();
select market.run_lifecycle();
select is((select status::text from market.campaigns where id = '55555555-0000-0000-0000-0000000000b4'), 'settled', 'settling → settled setelah semua submisi settled');
select is((select count(*)::int from ops.notifications where event = 'campaign.new'), 3, 'campaign.new sekali per campaign per clipper (2 saat live + 1 clipper baru dari pengumuman ulang)');
select ok(exists (select 1 from ops.notifications where event = 'campaign.settled' and user_id = '22222222-0000-0000-0000-0000000000a1'
                  and payload ->> 'campaign_title' = 'Selesai' and payload -> 'leftover' -> 0 ->> 'amount' = '995000'
                  and payload -> 'leftover' -> 0 ->> 'unit_label' = 'Rp'), 'campaign.settled ke org dengan judul & sisa budget');

-- ========== N2. Sisa budget campaign settled: rollover vs refund (D-09) ==========
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1');
select throws_ok($$ select api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000b4', 'rollover',
                    300000, 'roll-key-1') $$, '42501', 'auth:forbidden', 'refund/rollover butuh aal2');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select throws_ok($$ select api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a1', 'refund',
                    1000, 'refund-live-1') $$, 'P0001', 'invalid_state:live', 'campaign yang masih berjalan tidak bisa direfund');
insert into t_pay select 'roll', api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000b4', 'rollover',
                                                    300000, 'roll-key-1');
select is(api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000b4', 'rollover', 300000, 'roll-key-1'),
          (select id from t_pay where k = 'roll'), 'rollover diulang dengan key sama = transaksi yang sama');
insert into t_pay select 'refund', api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000b4', 'refund',
                                                      500000, 'refund-key-1');
select throws_ok($$ select api.request_refund('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000b4', 'refund',
                    195001, 'refund-key-2') $$, 'P0001', 'insufficient_balance', 'refund melebihi sisa budget ditolak');
reset role;
select is(pg_temp.acct('campaign_pool', '66666666-0000-0000-0000-0000000000b4'), 195000::numeric, 'sisa pool berkurang rollover + refund');
select is((select sum(e.amount) from finance.ledger_entries e where e.ref_type = 'rollover'), 0::numeric, 'jurnal rollover seimbang');
select is((select e.amount from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
           where e.ref_type = 'rollover' and a.owner_type = 'org_credit'), 300000::numeric, 'rollover → org_credit');
select is((select status || ':' || transfer_fee from finance.org_refunds where id = (select id from t_pay where k = 'refund')), 'requested:2500.00',
          'refund sisa → E-35 requested dengan biaya transfer');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select api.set_refund_dest((select id from t_pay where k = 'refund'), '{"bank":"Mandiri","account_no":"9876543210","account_name":"PT Studio Satu"}');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select lives_ok($$ select api.approve_refund((select id from t_pay where k = 'refund')) $$, 'admin_finance menyetujui refund');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select throws_ok($$ select api.set_refund_dest((select id from t_pay where k = 'refund'),
                                               '{"bank":"BCA","account_no":"1111111111","account_name":"PT Studio Satu"}') $$,
                 'P0001', 'invalid_state:approved', 'rekening tidak bisa diganti setelah disetujui orang kedua');
reset role;
-- AB-6 perorangan: rekening pribadi tetap di identity; core hanya mencatat pemilik org yang memilih rekeningnya.
insert into market.organizations (id, name, org_type, status, verified_by, verified_at, created_by) values
  ('44444444-0000-0000-0000-0000000000e7', 'Toko Pribadi', 'perorangan', 'verified', '33333333-0000-0000-0000-0000000000f1', now(),
   '22222222-0000-0000-0000-0000000000a1');
insert into market.org_members (org_id, user_id, role) values
  ('44444444-0000-0000-0000-0000000000e7', '22222222-0000-0000-0000-0000000000a1', 'brand_owner'),
  ('44444444-0000-0000-0000-0000000000e7', '22222222-0000-0000-0000-0000000000c1', 'brand_finance');
with x as (insert into finance.org_refunds (org_id, amount, transfer_fee, requested_by, idempotency_key)
           values ('44444444-0000-0000-0000-0000000000e7', 100000, 2500, '22222222-0000-0000-0000-0000000000c1', 'ref-perorangan-1') returning id)
insert into t_pay select 'ref_p', id from x;
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select throws_ok($$ select api.set_refund_dest((select id from t_pay where k = 'ref_p'), '{"owner_account":true}') $$,
                 '42501', 'auth:forbidden', 'perorangan: rekening refund hanya milik pemilik org (bukan anggota finance)');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a1', '{"aal":"aal2"}');
select throws_ok($$ select api.set_refund_dest((select id from t_pay where k = 'ref_p'),
                                               '{"bank":"BCA","account_no":"1234567890","account_name":"Andi"}') $$,
                 'P0001', 'invalid:owner_account', 'perorangan: nomor rekening pribadi tidak disimpan di core');
select lives_ok($$ select api.set_refund_dest((select id from t_pay where k = 'ref_p'), '{"owner_account":true}') $$,
                'regresi AB-6: pemilik org perorangan memakai rekening pribadinya di Akun (identity)');
reset role;
select is(api.bridge_get_refund((select id from t_pay where k = 'ref_p')) - 'id' - 'requested_by',
          '{"status":"requested","approved_by":null,"company_account":false,"dest_set_by":"22222222-0000-0000-0000-0000000000a1","amount":100000.00,"fee":2500.00,"dest_owner_current":true}'::jsonb,
          'bridge_get_refund: identity membuka rekening pribadi dest_set_by');
-- R25-1: owner yang dikeluarkan tidak boleh tetap jadi tujuan refund: rekening dikosongkan, persetujuan batal
update market.org_members set role = 'brand_owner' where org_id = '44444444-0000-0000-0000-0000000000e7'
   and user_id = '22222222-0000-0000-0000-0000000000c1';
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select api.approve_refund((select id from t_pay where k = 'ref_p'));
reset role;
delete from market.org_members where org_id = '44444444-0000-0000-0000-0000000000e7' and user_id = '22222222-0000-0000-0000-0000000000a1';
select is((select status || ':' || coalesce(dest_set_by::text, '-') || ':' || coalesce(approved_by::text, '-') from finance.org_refunds
            where id = (select id from t_pay where k = 'ref_p')), 'requested:-:-',
          'regresi R25-1: owner dikeluarkan → rekening pribadinya lepas dari refund, persetujuan batal');
select ok(exists (select 1 from ops.audit_logs where action = 'refund.dest_reset' and target = 'refund:' || (select id from t_pay where k = 'ref_p')),
          'reset rekening refund tercatat di audit');
-- R26-1: rekening sudah dibuka finance (transfer dimulai) → tidak di-reset walau owner berubah (tidak dibayar dua kali)
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select api.set_refund_dest((select id from t_pay where k = 'ref_p'), '{"owner_account":true}');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select api.approve_refund((select id from t_pay where k = 'ref_p'));
reset role;
select throws_ok($$ select api.bridge_refund_revealed((select id from t_pay where k = 'ref_p'), '22222222-0000-0000-0000-0000000000a1') $$,
                 'P0001', 'refund_dest_invalid', 'rekening hanya dibuka untuk tujuan yang disetujui & owner sekarang');
select lives_ok($$ select api.bridge_refund_revealed((select id from t_pay where k = 'ref_p'), '22222222-0000-0000-0000-0000000000c1') $$,
                'identity mencatat transfer dimulai sebelum menampilkan rekening');
insert into market.org_members (org_id, user_id, role) values ('44444444-0000-0000-0000-0000000000e7', '22222222-0000-0000-0000-0000000000a1', 'brand_owner');
delete from market.org_members where org_id = '44444444-0000-0000-0000-0000000000e7' and user_id = '22222222-0000-0000-0000-0000000000c1';
select is((select status || ':' || coalesce(dest_set_by::text, '-') from finance.org_refunds where id = (select id from t_pay where k = 'ref_p')),
          'approved:22222222-0000-0000-0000-0000000000c1',
          'regresi R26-1: transfer yang sudah dimulai diselesaikan dengan bukti, tidak di-reset jadi refund baru');
select throws_ok($$ select api.bridge_attach_proof('refund', (select id from t_pay where k = 'refund'), 'payout-proofs/refund-1.pdf') $$,
                 'P0001', 'invalid:bank_ref', 'regresi C20-2: refund tidak bisa ditandai dibayar tanpa referensi mutasi bank');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select api.set_bank_ref('refund', (select id from t_pay where k = 'refund'), 'TRF-REFUND-SALAH');
select lives_ok($$ select api.set_bank_ref('refund', (select id from t_pay where k = 'refund'), 'TRF-REFUND-1') $$,
                'unggah bukti refund diulang dengan referensi baru: refund belum dibayar tidak perlu catatan');
reset role;
select is((select bank_ref from finance.org_refunds where id = (select id from t_pay where k = 'refund')), 'TRF-REFUND-1',
          'referensi refund mengikuti isian terakhir sebelum bukti terunggah');
select api.bridge_attach_proof('refund', (select id from t_pay where k = 'refund'), 'payout-proofs/refund-1.pdf');
select is((select status from finance.org_refunds where id = (select id from t_pay where k = 'refund')), 'paid', 'bukti transfer → refund paid');
select is((select jsonb_object_agg(a.owner_type, e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
           where e.ref_type = 'refund' and e.ref_id = (select id from t_pay where k = 'refund') || ':paid'),
          '{"org_credit":-500000, "bank_clearing":497500, "platform_revenue":2500}'::jsonb, 'refund dibayar: kas keluar dikurangi biaya transfer');

-- ========== O. Alert & overview admin ==========
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a');
select is((select count(*)::int from api.alerts), 0, 'clipper tidak melihat alert');
select throws_ok($$ select api.resolve_alert(1) $$, '42501', 'auth:forbidden', 'clipper tidak bisa menutup alert');
select throws_ok($$ select api.admin_overview() $$, '42501', 'auth:forbidden', 'overview hanya admin');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"]}');
select throws_ok($$ select api.admin_overview() $$, '42501', 'auth:forbidden', 'overview admin butuh aal2');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
select ok((select count(*) > 0 from api.alerts), 'admin aal2 melihat alert');
select lives_ok($$ select api.resolve_alert((select min(id) from api.alerts)) $$, 'admin menutup alert');
select throws_ok($$ select api.resolve_alert((select min(id) from api.alerts)) $$, 'P0002', 'not_found:alert', 'alert yang sudah ditutup');
create temp table t_ov on commit drop as select api.admin_overview() as v;
reset role;
select is((select v -> 'gmv' ->> 'all_time' from t_ov), '21670600.00', 'GMV = Σ invoice lunas (tagihan tunai)');
select is((select v -> 'payout_pending' from t_ov), '{"count": 1, "sum": 100000.00}'::jsonb, 'payout pending (b3 dibatalkan, i3 requested)');
select ok((select (v ->> 'fraud_queue')::int > 0 and (v ->> 'active_campaigns')::int > 0 and v -> 'tracking' ? 'overdue'
                  and v -> 'tracking' ? 'last_snapshot_age_seconds' and v ? 'open_alerts' and v -> 'revenue' ? 'month' from t_ov),
          'overview: fraud queue, campaign aktif, kesehatan tracking, alert');

-- ========== N3. Kredit org (rollover D-09) dipakai membayar invoice ==========
insert into t_pay select 'inv_credit', (finance.issue_invoice('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a1',
                                                              'pinned', 0, 100000, now() + interval '7 days')).id;
insert into t_pay select 'inv_big', (finance.issue_invoice('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000a1',
                                                           'pinned', 0, 900000, now() + interval '7 days')).id;
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1');
select throws_ok($$ select api.pay_invoice_with_credit((select id from t_pay where k = 'inv_credit')) $$, '42501', 'auth:mfa_required',
                 'bayar pakai kredit butuh aal2');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select is((select v ->> 'available' from (select api.org_credit('44444444-0000-0000-0000-000000000001') v) x), '300000',
          'kredit tersedia = rollover (refund yang sudah dibayar tidak dihitung)');
select is((select v -> 'leftovers' -> 0 ->> 'amount' from (select api.org_credit('44444444-0000-0000-0000-000000000001') v) x), '195000',
          'sisa campaign settled dari ledger campaign_pool');
select lives_ok($$ select api.pay_invoice_with_credit((select id from t_pay where k = 'inv_credit')) $$, 'invoice dibayar dari kredit org');
select lives_ok($$ select api.pay_invoice_with_credit((select id from t_pay where k = 'inv_credit')) $$, 'bayar ulang = no-op');
select is((select v ->> 'available' from (select api.org_credit('44444444-0000-0000-0000-000000000001') v) x), '189000',
          'kredit berkurang total invoice (fee + pajak) sekali');
-- Kredit sebagian (inv_big total 999.000 > kredit 189.000): dicadangkan, sisa dibayar transfer.
select throws_ok($$ select api.pay_invoice_with_credit((select id from t_pay where k = 'inv_big'), 500000) $$, 'P0001', 'insufficient_credit',
                 'minta kredit melebihi yang tersedia ditolak');
select is(api.pay_invoice_with_credit((select id from t_pay where k = 'inv_big')), '{"credit_applied": 189000, "due": 810000, "paid": false}'::jsonb,
          'kredit sebagian dicadangkan, sisa tagihan 810.000');
select is((select v ->> 'available' || '/' || (v ->> 'reserved') from (select api.org_credit('44444444-0000-0000-0000-000000000001') v) x), '0/189000',
          'kredit yang dicadangkan tidak bisa dipakai dua kali');
select is(api.pay_invoice_with_credit((select id from t_pay where k = 'inv_big'), 0) ->> 'due', '999000', 'cadangan bisa dilepas (p_amount 0)');
select is(api.pay_invoice_with_credit((select id from t_pay where k = 'inv_big')) ->> 'credit_applied', '189000', 'cadangkan lagi');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select throws_ok($$ select api.confirm_invoice_payment((select id from t_pay where k = 'inv_big'), 999000, now(), 'REF-MIX-1', 'transfer') $$,
                 'P0001', 'amount_mismatch', 'konfirmasi wajib sebesar sisa tagihan setelah kredit');
select lives_ok($$ select api.confirm_invoice_payment((select id from t_pay where k = 'inv_big'), 810000, now(), 'REF-MIX-1', 'transfer') $$,
                'sisa tagihan dikonfirmasi');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select is((select v ->> 'available' || '/' || (v ->> 'reserved') from (select api.org_credit('44444444-0000-0000-0000-000000000001') v) x), '0/0',
          'setelah lunas kredit terpakai (bukan cadangan lagi)');
reset role;
select is((select jsonb_object_agg(a.owner_type, e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
            where e.ref_type = 'invoice_payment' and e.ref_id = (select id::text from t_pay where k = 'inv_big')
              and a.owner_type in ('bank_clearing', 'org_credit')),
          '{"bank_clearing": -810000, "org_credit": -189000}'::jsonb, 'jurnal dua kaki: kas + kredit org = total');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000a2', '{"aal":"aal2"}');
select throws_ok($$ select api.org_credit('44444444-0000-0000-0000-000000000001') $$, '42501', 'auth:forbidden', 'org lain tidak melihat kredit');
reset role;
select is((select status || ':' || payment_channel from finance.invoices where id = (select id from t_pay where k = 'inv_credit')), 'paid:credit',
          'invoice lunas lewat kanal credit');
select ok((select pinned_until is not null from market.campaigns where id = '55555555-0000-0000-0000-0000000000a1'), 'pinned diterapkan');
set constraints all immediate;
set constraints all deferred;

select is((select array_agg(distinct action order by action) from ops.audit_logs
            where action in ('invoice.confirm_payment', 'payout_batch.create', 'payout_batch.approve', 'payout_batch.mark_paid', 'refund.approve')),
          array['invoice.confirm_payment', 'payout_batch.approve', 'payout_batch.create', 'payout_batch.mark_paid', 'refund.approve'],
          'aksi finance admin tercatat audit log (F-A11)');
-- G-10 (F-A08): ledger terbaca di back-office finance — hanya admin_finance
insert into t_ids select 'ledger_n', count(*)::text from finance.ledger_entries;
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select is((select count(*)::text from api.admin_ledger), (select v from t_ids where k = 'ledger_n'),
          'regresi G-10: admin_finance membaca seluruh ledger');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000a0', '{"app_roles":["admin_ops"],"aal":"aal2"}');
select is((select count(*)::int from api.admin_ledger), 0, 'admin_ops tidak membaca ledger');
select pg_temp.jwt('11111111-0000-0000-0000-00000000000a', '{}');
select is((select count(*)::int from api.admin_ledger), 0, 'clipper tidak membaca ledger');

reset role;
-- Regresi review 2026-10-19: views final turun di bawah awal rule baru (rate naik di 2.000 views) → rule baru hangus, bukan error
insert into market.profiles (id, username, display_name) values ('11111111-0000-0000-0000-0000000000c9', 'koreksi_c9', 'Koreksi');
insert into tracking.social_accounts (user_id, platform, external_id, handle, followers, platform_created_at)
values ('11111111-0000-0000-0000-0000000000c9', 'tiktok', 'tt-c9', '@koreksi', 5000, now() - interval '400 days');
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000c9', 'koreksi-rule-baru', 1000);
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000c9', '66666666-0000-0000-0000-0000000000c9', 1000000, 1000000);
insert into t_ids values ('rc_old', pg_temp.mk_rule('55555555-0000-0000-0000-0000000000c9', '66666666-0000-0000-0000-0000000000c9',
  'per_1k_views', '{"rate":2000}', now() - interval '30 days', now() - interval '1 hour'));
insert into t_ids values ('rc_new', pg_temp.mk_rule('55555555-0000-0000-0000-0000000000c9', '66666666-0000-0000-0000-0000000000c9',
  'per_1k_views', '{"rate":3000}', now() - interval '1 hour'));
insert into t_ids values ('rc_sub', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000c9', '11111111-0000-0000-0000-0000000000c9', 'rc1',
  now() - interval '3 hours'));
select pg_temp.snap((select v::uuid from t_ids where k = 'rc_sub'), 2000, now() - interval '2 hours');
select pg_temp.snap((select v::uuid from t_ids where k = 'rc_sub'), 5000, now() - interval '30 minutes');
select lives_ok($$ select pg_temp.snap((select v::uuid from t_ids where k = 'rc_sub'), 1500, now(), true) $$,
                'snapshot final di bawah awal rule baru tidak menggagalkan finalisasi');
select is(array[pg_temp.rule_amt((select v::uuid from t_ids where k = 'rc_sub'), (select v::uuid from t_ids where k = 'rc_old')),
                pg_temp.rule_amt((select v::uuid from t_ids where k = 'rc_sub'), (select v::uuid from t_ids where k = 'rc_new'))],
          array[3000, 0]::numeric[], 'rule lama dikoreksi ke 1.500 views, rule baru hangus');

-- Regresi review R10: clipper_fee_pct (E-21) dipotong saat earning Rupiah dirilis → platform_revenue.
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000fe', 'fee-clipper');
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000fe', '66666666-0000-0000-0000-0000000000fe', 1000000, 1000000);
select pg_temp.mk_rule('55555555-0000-0000-0000-0000000000fe', '66666666-0000-0000-0000-0000000000fe', 'per_1k_views', '{"rate":1000}');
update market.campaigns set fee_rule_id = finance.create_fee_rule('campaign', '{"clipper_fee_pct":10}',
                                                                   finance.effective_fee_rule('44444444-0000-0000-0000-000000000001', null),
                                                                   '33333333-0000-0000-0000-0000000000f1')
 where id = '55555555-0000-0000-0000-0000000000fe';
insert into t_ids select 'sfee', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000fe', '11111111-0000-0000-0000-0000000000c9', 'vfee');
select pg_temp.snap((select v::uuid from t_ids where k = 'sfee'), 10000);
update tracking.submissions set status = 'locked', locked_at = now() - interval '8 days' where id = (select v::uuid from t_ids where k = 'sfee');
select finance.release_earnings();
select is((select array[sum(e.amount) filter (where e.ref_type = 'release' and e.state = 'available'),
                        sum(e.amount) filter (where e.ref_type = 'fee' and a.owner_type = 'platform_revenue')]
             from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
            where e.ref_id like (select v from t_ids where k = 'sfee') || ':%'),
          array[9000, 1000]::numeric[], 'regresi R10: fee clipper 10% dipotong saat rilis (Rp10.000 → Rp9.000 Tersedia + Rp1.000 platform)');

-- job:reconcile-daily bagian ledger: bersih, lalu selisih cache pool terdeteksi + alert
-- Fixture memakai jalan pintas: pool didanai jurnal ref 'fixture:<pool>' tanpa invoice, invoice c5 di-insert langsung lunas.
create temp table t_reconcile on commit drop as select finance.reconcile_ledger() as v;
select ok((select not (v ? 'pool_cache') and not (v ? 'negative_wallet') from t_reconcile), 'rekonsiliasi: cache pool & saldo clipper bersih');
select is((select v -> 'invoice_unposted' from t_reconcile), '["dddddddd-0000-0000-0000-0000000000c5"]'::jsonb,
          'rekonsiliasi: invoice lunas tanpa jurnal pembayaran terdeteksi');
select ok((select (select bool_and(x like 'fixture:%') from jsonb_array_elements_text(v -> 'journal_without_invoice') x) from t_reconcile),
          'rekonsiliasi: jurnal pembayaran tanpa invoice terdeteksi (hanya jalan pintas fixture)');
update finance.reward_pools set allocated = allocated + 1 where id = '66666666-0000-0000-0000-0000000000a1';
select ok(finance.reconcile_ledger() ? 'pool_cache', 'selisih cache pool vs jurnal terdeteksi');
select ok(exists (select 1 from ops.alerts where kind = 'reconcile.ledger' and severity = 'critical'), 'alert rekonsiliasi ledger');
update finance.reward_pools set allocated = allocated - 1 where id = '66666666-0000-0000-0000-0000000000a1';

-- Regresi G-11 (F-A08, A3.5, §16): mutasi rekening bank vs kas sistem per referensi; selisih → alert reconcile.bank.
create temp table t_bank on commit drop as
  select 'inv'::text k, i.payment_ref ref, i.paid_amount amt, i.id from finance.invoices i
   where i.status = 'paid' and i.payment_channel = 'transfer' order by i.paid_at, i.id limit 1;
insert into t_bank select 'po', p.bank_ref, -(p.amount - p.fee), p.id from finance.payouts p
 where p.status = 'paid' and p.channel = 'batch' and p.bank_ref is not null order by p.paid_at, p.id limit 1;
select is((select count(*)::int from t_bank), 2, 'fixture rekonsiliasi bank: invoice transfer & payout batch dibayar');
create temp table t_bank_in on commit drop as
  select jsonb_build_array(
    jsonb_build_object('date', (now() at time zone 'Asia/Jakarta')::date, 'amount', (select amt from t_bank where k = 'inv'),
                       'reference', (select ref from t_bank where k = 'inv'), 'description', 'TRF BRAND'),
    jsonb_build_object('date', (now() at time zone 'Asia/Jakarta')::date, 'amount', (select amt from t_bank where k = 'po'),
                       'reference', (select ref from t_bank where k = 'po'), 'description', 'TRF MASSAL'),
    jsonb_build_object('date', (now() at time zone 'Asia/Jakarta')::date, 'amount', -6500, 'reference', 'BIAYA-ADM', 'description', 'biaya admin'),
    jsonb_build_object('date', (now() at time zone 'Asia/Jakarta')::date, 'amount', 1000000, 'reference', 'TAK-DIKENAL', 'description', '')) v;
grant select on t_bank, t_bank_in to authenticated;
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
select throws_ok($$ select api.import_bank_lines((select v from t_bank_in)) $$, '42501', 'auth:forbidden', 'impor mutasi bank hanya admin_finance');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select throws_ok($$ select api.import_bank_lines('[{"date":"20-10-2026","amount":1,"reference":"x"}]') $$, 'P0001', 'invalid:bank_lines',
                 'baris mutasi tidak valid ditolak');
select is((api.import_bank_lines((select v from t_bank_in)) ->> 'inserted')::int, 4, 'impor 4 baris mutasi');
select is((api.import_bank_lines((select v from t_bank_in)) ->> 'inserted')::int, 0, 'unggah ulang file yang sama tidak menggandakan baris');
reset role;
select is((select array_agg(b.status order by b.reference) from finance.bank_lines b where b.reference in (select ref from t_bank)),
          array['matched', 'matched'], 'kredit invoice (payment_ref + nominal) dan debit payout (bank_ref + nett) cocok');
select ok((select (payload -> 'bank_unmatched') @> (select jsonb_agg(b.id) from finance.bank_lines b where b.reference in ('BIAYA-ADM', 'TAK-DIKENAL'))
             from ops.alerts where kind = 'reconcile.bank' order by id desc limit 1),
          'baris bank tanpa transaksi sistem → alert reconcile.bank');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select lives_ok($$ select api.resolve_bank_line((select id from api.bank_lines where reference = 'BIAYA-ADM'), 'biaya admin bulanan bank') $$,
                'baris biaya bank ditutup manual dengan catatan');
select throws_ok($$ select api.import_bank_lines(jsonb_build_array((select v -> 0 from t_bank_in))) $$, 'P0001',
                 'bank_partial_day:' || (now() at time zone 'Asia/Jakarta')::date,
                 'regresi R18-1: potongan file yang tidak memuat semua mutasi tersimpan tanggal itu ditolak, bukan dibuang diam-diam');
select is((api.import_bank_lines((select v from t_bank_in) || jsonb_build_array((select v -> 0 from t_bank_in))) ->> 'inserted')::int, 1,
          'regresi R18-1: mutasi kembar (tanggal, nominal, referensi, keterangan sama) di file sehari penuh tetap tersimpan');
reset role;
select is((select array_agg(distinct b.status) from finance.bank_lines b where b.reference = (select ref from t_bank where k = 'inv')),
          array['open'], 'dana masuk dua kali untuk satu invoice → selisih (tidak dianggap cocok)');
update finance.payouts set bank_ref = 'REF-SALAH' where id = (select id from t_bank where k = 'po');
update finance.payouts set paid_at = now() where id = (select id from t_bank where k = 'po');
select ok(finance.reconcile_bank() -> 'missing_in_bank' ? ('payout:' || (select id from t_bank where k = 'po')),
          'payout dibayar di rentang mutasi tanpa baris bank → selisih');
select is((select status from finance.bank_lines where reference = (select ref from t_bank where k = 'po')), 'open',
          'baris bank yang tadinya cocok dibuka lagi saat kas sistem berubah');
create temp table t_bank_alerts on commit drop as select count(*) n from ops.alerts where kind = 'reconcile.bank';
select finance.reconcile_bank();
select is((select count(*) from ops.alerts where kind = 'reconcile.bank'), (select n from t_bank_alerts),
          'regresi C20-4: rekonsiliasi ulang dengan selisih yang sama tidak membuat alert baru');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select ok(api.bank_issues() -> 'missing_in_bank' ? ('payout:' || (select id from t_bank where k = 'po')),
          'regresi C20-4: tab Mutasi bank membaca selisih terkini (api.bank_issues), bukan payload alert lama');
select throws_ok($$ select api.set_bank_ref('payout', (select id from t_bank where k = 'po'), (select ref from t_bank where k = 'po')) $$,
                 'P0001', 'invalid:note', 'koreksi referensi yang sudah ada wajib catatan');
select ok(not (api.set_bank_ref('payout', (select id from t_bank where k = 'po'), (select ref from t_bank where k = 'po'), 'salah ketik')
               -> 'missing_in_bank' ? ('payout:' || (select id from t_bank where k = 'po'))),
          'regresi C20-3: referensi payout salah ketik bisa dikoreksi (tercatat audit) lalu cocok lagi');
reset role;
select is((select status from finance.bank_lines where reference = (select ref from t_bank where k = 'po')), 'matched',
          'baris bank payout cocok lagi setelah koreksi referensi');
select is((select count(*) from ops.alerts where kind = 'reconcile.bank'), (select n from t_bank_alerts),
          'selisih berkurang (koreksi) tidak membuat alert baru');
select ok((select count(*) from ops.alerts where kind = 'reconcile.bank') >= 3,
          'regresi C20-4: tiap selisih baru (baris tak dikenal, kredit ganda, payout tanpa mutasi) dikabari alert baru walau alert lama masih terbuka');
insert into t_bank select 'po_batch', null, null, p.batch_id from finance.payouts p where p.id = (select id from t_bank where k = 'po');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select api.mark_batch_paid((select id from t_bank where k = 'po_batch'),
                           jsonb_build_array(jsonb_build_object('payout_id', (select id from t_bank where k = 'po'), 'status', 'failed',
                                                                'reason', 'retur bank')));
reset role;
select is((select status from finance.bank_lines where reference = (select ref from t_bank where k = 'po')), 'open',
          'regresi R19-3: retur bank lewat mark_batch_paid langsung membuka lagi baris mutasi (tanpa menunggu rekonsiliasi harian)');

-- Regresi review R14: ban dari fraud queue bisa dicabut admin (profil core kembali active, bukan cuma login).
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
select throws_ok($$ select api.manage_user('11111111-0000-0000-0000-00000000000e', 'unban', '{}') $$, 'P0001', 'invalid:reason',
                 'cabut ban wajib alasan');
select lives_ok($$ select api.manage_user('11111111-0000-0000-0000-00000000000e', 'unban', '{"note":"banding diterima"}') $$,
                'admin mencabut ban profil');
reset role;
select is((select status::text from market.profiles where id = '11111111-0000-0000-0000-00000000000e'), 'active',
          'regresi R14: profil yang di-ban fraud queue kembali active');
select ok(exists (select 1 from ops.audit_logs where action = 'user.unban' and target = 'profile:11111111-0000-0000-0000-00000000000e'),
          'cabut ban tercatat audit log');

-- Regresi G-6: FR-03 juga untuk akun lama dengan follower sangat sedikit (config trust.fraud.low_followers, default 100).
insert into market.profiles (id, username, display_name) values ('11111111-0000-0000-0000-0000000000f3', 'sedikit_f3', 'Sedikit');
insert into tracking.social_accounts (user_id, platform, external_id, handle, followers, platform_created_at)
values ('11111111-0000-0000-0000-0000000000f3', 'tiktok', 'tt-f3', '@sedikit', 20, now() - interval '400 days');
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000f3', 'low-follower', 0);
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000f3', '66666666-0000-0000-0000-0000000000f3', 1000000, 1000000);
select pg_temp.mk_rule('55555555-0000-0000-0000-0000000000f3', '66666666-0000-0000-0000-0000000000f3', 'per_1k_views', '{"rate":10}');
insert into t_ids select 'sf3', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000f3', '11111111-0000-0000-0000-0000000000f3', 'vf3');
select api.worker_record_snapshot((select v::uuid from t_ids where k = 'sf3'), 150000, 20000, 900, 300, '#x', '{}', '{}');
select ok(exists (select 1 from trust.fraud_flags where signal = 'FR-03' and target_id = (select v::uuid from t_ids where k = 'sf3')),
          'regresi G-6: akun lama follower 20 dengan 150rb views → FR-03');
-- R16: follower tidak diketahui (YouTube hidden subscriber / Threads tanpa insight) bukan "follower sedikit"
insert into market.profiles (id, username, display_name) values ('11111111-0000-0000-0000-0000000000f6', 'tersembunyi_f6', 'Tersembunyi');
insert into tracking.social_accounts (user_id, platform, external_id, handle, followers, platform_created_at)
values ('11111111-0000-0000-0000-0000000000f6', 'tiktok', 'tt-f6', '@tersembunyi', null, now() - interval '400 days');
insert into t_ids select 'sf6', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000f3', '11111111-0000-0000-0000-0000000000f6', 'vf6');
select api.worker_record_snapshot((select v::uuid from t_ids where k = 'sf6'), 150000, 20000, 900, 300, '#x', '{}', '{}');
select ok(not exists (select 1 from trust.fraud_flags where signal = 'FR-03' and target_id = (select v::uuid from t_ids where k = 'sf6')),
          'regresi R16: follower null tidak memicu FR-03');
-- Regresi R17: retry tertunda (Retry-After/backoff) → penjadwal tidak mengantre ulang submisi itu walau next_poll_at lewat
update tracking.submissions set next_poll_at = now() - interval '1 minute' where id = (select v::uuid from t_ids where k = 'sf6');
select api.worker_retry_later('tracking', 0, 3600, (select v::uuid from t_ids where k = 'sf6'));
select tracking.enqueue_due_submissions();
select ok(not exists (select 1 from pgmq.q_tracking where message ->> 'submission_id' = (select v from t_ids where k = 'sf6')),
          'regresi R17: penjadwal menunggu retry_after (poll final di ujung window tidak memotong backoff)');
-- Regresi audit 2 AA-6: worker mati → pesan menumpuk di antrean, next_poll_at terus digeser lease → tetap terdeteksi macet.
update tracking.submissions set retry_after = null, next_poll_at = now() - interval '1 minute' where id = (select v::uuid from t_ids where k = 'sf6');
select tracking.enqueue_due_submissions();
update pgmq.q_tracking set enqueued_at = now() - interval '90 minutes' where message ->> 'submission_id' = (select v from t_ids where k = 'sf6');
select is((select count(*)::int from tracking.submissions where id = (select v::uuid from t_ids where k = 'sf6')
             and next_poll_at < now() - interval '2 hours'), 0, 'next_poll_at sudah digeser lease (metrik lama tidak melihatnya)');
select ok(tracking.lagging_count() >= 1, 'regresi AA-6: antrean tracking tidak diproses > 1 jam = tracking macet (alert & overview)');

-- Regresi G-7: teman satu perangkat dengan pengundang (FR-05) → bonus referral batal selama flag belum di-dismiss.
insert into market.profiles (id, username, display_name) values
  ('11111111-0000-0000-0000-0000000000f4', 'teman_f4', 'Teman'), ('11111111-0000-0000-0000-0000000000f5', 'pengundang_f5', 'Pengundang');
insert into market.referrals (referred_id, referrer_id, code, qualified_at, bonus_until) values
  ('11111111-0000-0000-0000-0000000000f4', '11111111-0000-0000-0000-0000000000f5', 'f5code', now() - interval '1 day', now() + interval '30 days');
select finance.post(gen_random_uuid(), jsonb_build_array(  -- jalan pintas: earning teman Rp10.000 jadi Tersedia
  finance.e(finance.account('platform_revenue', null, finance.idr()), -10000, 'release', 'fixture-f4'),
  finance.e(finance.account('user_wallet', '11111111-0000-0000-0000-0000000000f4', finance.idr()), 10000, 'release', 'fixture-f4', 'available')));
insert into t_pay select 'fl_f5', trust.raise_flag('profile', '11111111-0000-0000-0000-0000000000f4', 'FR-05', 60,
  '{"related_user_ids":["11111111-0000-0000-0000-0000000000f5"]}');
select finance.accrue_referral_bonus();
select is(pg_temp.bal('11111111-0000-0000-0000-0000000000f5', 'available'), 0::numeric, 'regresi G-7: satu perangkat → bonus tidak dibayar');
update trust.fraud_flags set status = 'dismissed', resolved_by = '33333333-0000-0000-0000-0000000000e1', resolved_at = now()
 where id = (select id from t_pay where k = 'fl_f5');
select finance.accrue_referral_bonus();
select is(pg_temp.bal('11111111-0000-0000-0000-0000000000f5', 'available'), 500::numeric, 'flag di-dismiss → bonus berjalan lagi (5%)');

-- Regresi G-14: ban dari manajemen user mengubah status profil core (JWT lama tidak bisa claim/submit); unban mencabut ban & suspend.
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
select lives_ok($$ select api.manage_user('11111111-0000-0000-0000-0000000000f4', 'ban', '{"reason":"spam"}') $$, 'admin ban profil core');
reset role;
select is((select status::text from market.profiles where id = '11111111-0000-0000-0000-0000000000f4'), 'banned', 'regresi G-14: profil core banned');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
select api.manage_user('11111111-0000-0000-0000-0000000000f4', 'unban', '{"note":"salah orang"}');
select api.manage_user('11111111-0000-0000-0000-0000000000f4', 'suspend',
                       jsonb_build_object('until', now() + interval '1 hour', 'reason', 'ban login 1 jam'));
reset role;
select is((select suspended_until from market.profiles where id = '11111111-0000-0000-0000-0000000000f4'), now() + interval '1 hour',
          'regresi R16: suspend core berakhir persis saat ban login berakhir');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
select api.manage_user('11111111-0000-0000-0000-0000000000f4', 'unban', '{"note":"banding diterima"}');
reset role;
select is((select status::text || ':' || coalesce(suspended_until::text, 'null') from market.profiles where id = '11111111-0000-0000-0000-0000000000f4'),
          'active:null', 'unban juga mencabut suspend hasil ban berdurasi');

-- Regresi G-2/G-4 (§12, C4.1): Trust Score tinggi → cap per klip lebih tinggi & hold lebih pendek; TikTok → cap lebih rendah
-- & hold lebih panjang (config per platform). Pool cap Rp1.000/klip, rate Rp1/view.
insert into ops.settings (key, value) values
  ('public.finance.trust_tiers', '[{"min_score":80,"cap_pct":150,"hold_days":3},{"min_score":60,"cap_pct":100,"hold_days":5}]'),
  ('public.finance.platform_rules', '{"tiktok":{"cap_pct":80,"hold_days":10}}')
on conflict (key) do update set value = excluded.value;
insert into market.profiles (id, username, display_name, trust_score) values
  ('11111111-0000-0000-0000-0000000000f8', 'tepercaya_f8', 'Tepercaya', 85), ('11111111-0000-0000-0000-0000000000f9', 'biasa_f9', 'Biasa', 50);
insert into tracking.social_accounts (user_id, platform, external_id, handle, status, followers, platform_created_at) values
  ('11111111-0000-0000-0000-0000000000f8', 'tiktok', 'tt-f8', '@tepercaya', 'verified', 5000, now() - interval '400 days'),
  ('11111111-0000-0000-0000-0000000000f9', 'tiktok', 'tt-f9', '@biasa', 'verified', 5000, now() - interval '400 days');
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000f8', 'trust-terms', 0);
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000f8', '66666666-0000-0000-0000-0000000000f8', 1000000, 1000);
select pg_temp.mk_rule('55555555-0000-0000-0000-0000000000f8', '66666666-0000-0000-0000-0000000000f8', 'per_1k_views', '{"rate":1000}');
insert into t_ids select 'sf8', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000f8', '11111111-0000-0000-0000-0000000000f8', 'vf8');
insert into t_ids select 'sf9', pg_temp.mk_sub('55555555-0000-0000-0000-0000000000f8', '11111111-0000-0000-0000-0000000000f9', 'vf9');
select pg_temp.snap((select v::uuid from t_ids where k = k1), 10000) from (values ('sf8'), ('sf9')) x(k1);
select is((select array_agg(ce.amount order by s.user_id) from finance.clip_earnings ce join tracking.submissions s on s.id = ce.submission_id
            where ce.pool_id = '66666666-0000-0000-0000-0000000000f8'), array[1200, 800]::numeric[],
          'regresi G-2/G-4: cap per klip = cap pool × tier skor (150%) × TikTok (80%) → Rp1.200 vs Rp800');
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-0000000000f8');
select is(api.my_clip_terms() -> 'tiktok', '{"cap_pct":120,"hold_days":10}'::jsonb,
          'regresi C19-5/6: my_clip_terms = ketentuan accrual & release clipper ini (skor 85, TikTok)');
reset role;
update tracking.submissions set status = 'locked', locked_at = now() - interval '4 days'
 where id in (select v::uuid from t_ids where k in ('sf8', 'sf9'));
select finance.release_earnings();
select is((select array_agg(status::text order by user_id) from tracking.submissions where id in (select v::uuid from t_ids where k in ('sf8', 'sf9'))),
          array['locked', 'locked'], 'hold TikTok (min 10 hari) berlaku walau tier skor memberi 3 hari');
delete from ops.settings where key = 'public.finance.platform_rules';
select finance.release_earnings();
select is((select array_agg(status::text order by user_id) from tracking.submissions where id in (select v::uuid from t_ids where k in ('sf8', 'sf9'))),
          array['settled', 'locked'], 'tanpa aturan platform: skor 85 → hold 3 hari (dirilis), skor 50 → hold global 7 hari');
update ops.settings set value = '[{"min_score":72.5,"cap_pct":"80%","hold_days":"x"},{"min_score":"60","cap_pct":120}]'
 where key = 'public.finance.trust_tiers';
insert into ops.settings (key, value) values ('public.finance.platform_rules', '{"tiktok":{"cap_pct":80.5,"hold_days":10.6},"x":5}');
select is((select array[ct.cap_pct, ct.hold_days] from finance.clip_terms(85, 'tiktok') ct),
          array[80.5, 11]::numeric[], 'regresi C19-3: nilai config bukan angka diabaikan, desimal dibulatkan (tidak error)');
select is((select ct.hold_days from finance.clip_terms(85, 'x') ct), (ops.cfg('public.finance.hold_days', '7'))::int,
          'aturan platform bukan objek diabaikan → hold global');
delete from ops.settings where key in ('public.finance.trust_tiers', 'public.finance.platform_rules');

-- Regresi audit 2 AA-1/AA-3/AA-7: batch payout = checkpoint sanksi; tahan & lepas tahan payout oleh finance.
insert into market.profiles (id, username, display_name) values ('11111111-0000-0000-0000-000000000f10', 'payhold_f10', 'Pay Hold');
select finance.post(gen_random_uuid(), jsonb_build_array(
  finance.e(finance.account('bank_clearing', null, finance.idr()), -500000, 'adjustment', 'fixture:f10'),
  finance.e(finance.account('user_wallet', '11111111-0000-0000-0000-000000000f10', finance.idr()), 500000, 'adjustment', 'fixture:f10', 'available')));
set local role authenticated;
select pg_temp.jwt('11111111-0000-0000-0000-000000000f10', '{"kyc":"approved"}');
insert into t_pay select 'ph1', (api.request_payout('aaaaaaaa-0000-0000-0000-000000000f10', 150000, 'batch', 'idem-hold-f10')).id;
reset role;
select trust.raise_flag('profile', '11111111-0000-0000-0000-000000000f10', 'FR-05', 60, '{}');
select is((select status || ':' || hold_reason from finance.payouts where id = (select id from t_pay where k = 'ph1')), 'on_hold:fraud_flag',
          'regresi AA-1: flag profil terbuka → payout yang belum ditransfer langsung ditahan');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select throws_ok($$ select api.release_payout((select id from t_pay where k = 'ph1'), 'sudah dicek') $$, 'P0001', 'payout_blocked:fraud_flag',
                 'regresi AA-3: lepas tahan ditolak selama flag masih terbuka');
reset role;
update trust.fraud_flags set status = 'dismissed', resolved_by = '33333333-0000-0000-0000-0000000000e1', resolved_at = now()
 where target_id = '11111111-0000-0000-0000-000000000f10' and signal = 'FR-05';
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select lives_ok($$ select api.release_payout((select id from t_pay where k = 'ph1'), 'flag di-dismiss moderator') $$,
                'regresi AA-3: lepas tahan → kembali antre batch (S-05 on_hold → requested)');
select lives_ok($$ select api.hold_payout((select id from t_pay where k = 'ph1'), 'nominal mencurigakan') $$,
                'regresi AA-3: finance menahan payout tanpa mengembalikan dana');
select is((select status || ':' || hold_reason from api.payouts where id = (select id from t_pay where k = 'ph1')), 'on_hold:nominal mencurigakan',
          'payout tertahan dengan alasan');
select lives_ok($$ select api.release_payout((select id from t_pay where k = 'ph1'), 'aman') $$, 'lepas tahan lagi');
reset role;
update market.profiles set status = 'banned' where id = '11111111-0000-0000-0000-000000000f10';
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select api.create_payout_batch(now());
reset role;
select is((select status || ':' || hold_reason || ':' || (batch_id is null)::text from finance.payouts where id = (select id from t_pay where k = 'ph1')),
          'on_hold:profile_banned:true', 'regresi AA-1: buat batch menahan payout clipper yang di-ban, tidak ikut ditransfer');
update market.profiles set status = 'active' where id = '11111111-0000-0000-0000-000000000f10';
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select api.release_payout((select id from t_pay where k = 'ph1'), 'banding diterima');
insert into t_pay select 'ph_batch', api.create_payout_batch(now());
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f2', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select api.approve_payout_batch((select id from t_pay where k = 'ph_batch'));
reset role;
update market.profiles set status = 'suspended', suspended_until = now() + interval '3 days' where id = '11111111-0000-0000-0000-000000000f10';
select is((select x ->> 'blocked' from jsonb_array_elements(api.bridge_get_batch((select id from t_pay where k = 'ph_batch')) -> 'payouts') x
            where x ->> 'id' = (select id::text from t_pay where k = 'ph1')), 'profile_suspended',
          'regresi AA-1: batch disetujui → export menandai payout clipper yang disuspend (identity menahannya)');
select throws_ok($$ select api.bridge_attach_export((select id from t_pay where k = 'ph_batch'), 'payout-exports/ph.csv', '[]',
                    (select array_agg(p.id) from finance.payouts p where p.batch_id = (select id from t_pay where k = 'ph_batch') and p.status = 'requested')) $$,
                 'P0001', 'export_stale', 'regresi R21-1: sanksi di antara get_batch dan attach_export → CSV basi ditolak');
update market.profiles set status = 'active', suspended_until = null where id = '11111111-0000-0000-0000-000000000f10';
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000e1', '{"app_roles":["admin_moderator"],"aal":"aal2"}');
select api.manage_user('11111111-0000-0000-0000-000000000f10', 'ban', '{"reason":"pelanggaran ToS"}');
reset role;
select ok(exists (select 1 from ops.notifications where user_id = '11111111-0000-0000-0000-000000000f10' and event = 'account.banned'),
          'regresi AA-7: ban dari manajemen user mengabari clipper (paritas dengan ban fraud queue)');

-- Regresi audit 2 AB-2 (§5.3 D-09): budget campaign baru yang didanai kredit rollover tidak dikenai fee lagi.
select pg_temp.mk_campaign('55555555-0000-0000-0000-0000000000fa', 'roll-fee', 0);
select pg_temp.mk_pool('55555555-0000-0000-0000-0000000000fa', '66666666-0000-0000-0000-0000000000fa', 1000000, 100000);
select finance.post(gen_random_uuid(), jsonb_build_array(
  finance.e(finance.account('bank_clearing', null, finance.idr()), -1000000, 'rollover', 'fixture:roll-fee'),
  finance.e(finance.account('org_credit', '44444444-0000-0000-0000-000000000001', finance.idr()), 1000000, 'rollover', 'fixture:roll-fee')));
insert into t_pay select 'inv_roll', (finance.issue_invoice('44444444-0000-0000-0000-000000000001', '55555555-0000-0000-0000-0000000000fa',
                                                            'campaign', 1000000)).id;
select is((select mgmt_fee + admin_fee + tax from finance.invoices where id = (select id from t_pay where k = 'inv_roll')), 222000::numeric,
          'invoice campaign terbit dengan fee 15% + 5% + pajak 11% (belum tahu sumber dana)');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select api.pay_invoice_with_credit((select id from t_pay where k = 'inv_roll'), 500000);
reset role;
select is((select array[fee_exempt, mgmt_fee + admin_fee + tax, credit_applied] from finance.invoices where id = (select id from t_pay where k = 'inv_roll')),
          array[500000, 111000, 500000]::numeric[], 'kredit sebagian: hanya porsi rollover yang dipakai bebas fee');
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select api.pay_invoice_with_credit((select id from t_pay where k = 'inv_roll'), 0);
reset role;
select is((select array[fee_exempt, mgmt_fee + admin_fee + tax, total, credit_applied] from finance.invoices
            where id = (select id from t_pay where k = 'inv_roll')),
          array[0, 222000, 1222000, 0]::numeric[], 'regresi R22-1: lepas kredit → fee & pajak kembali penuh (bebas fee hanya selama didanai rollover)');
-- UI (InvoiceCredit) mengirim creditCap = min(total sebelum bebas fee, kredit tersedia); total turun setelah fee dibebaskan.
create temp table t_cap as select least(1222000, finance.org_credit_available('44444444-0000-0000-0000-000000000001')) as v;
grant select on t_cap to authenticated;
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select is(api.pay_invoice_with_credit((select id from t_pay where k = 'inv_roll'), (select v from t_cap)) ->> 'paid', 'true',
          'regresi R22-2: jumlah dari UI (≥ total setelah bebas fee) melunasi invoice, bukan insufficient_credit');
reset role;
select is((select array[fee_exempt, mgmt_fee, admin_fee, tax, total] from finance.invoices where id = (select id from t_pay where k = 'inv_roll')),
          array[1000000, 0, 0, 0, 1000000]::numeric[],
          'regresi AB-2: porsi budget dari rollover tanpa fee baru (fee & pajaknya dihapus, total = budget)');
select is(finance.rollover_available('44444444-0000-0000-0000-000000000001'),
          300000::numeric, 'rollover terpakai tercatat di fee_exempt (1 jt), sisa rollover lama 300 rb; tidak membebaskan fee dua kali');

-- Regresi audit 2 AB-4 (B1.8 "unduh faktur setelah lunas"): finance mencatat faktur pajak + PDF, brand billing mengunduhnya.
insert into storage.buckets (id, name, public) values ('invoice-docs', 'invoice-docs', false) on conflict do nothing;
create temp table t_fk as select org_id || '/' || id || '/faktur.pdf' as path, id from finance.invoices where id = (select id from t_pay where k = 'inv_roll');
grant select on t_fk to authenticated;
set local role authenticated;
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select throws_ok($$ select api.attach_faktur((select id from t_fk), '010.000-26.00000001', (select path from t_fk)) $$, '42501', 'auth:forbidden',
                 'brand tidak bisa mengisi faktur sendiri');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('invoice-docs', (select path from t_fk)) $$, '42501', null,
                 'brand tidak bisa mengunggah ke invoice-docs');
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
select throws_ok($$ select api.attach_faktur((select id from t_fk), '010.000-26.00000001', (select path from t_fk)) $$, 'P0001', 'file_missing',
                 'faktur wajib berkas yang sudah diunggah');
insert into storage.objects (bucket_id, name) values ('invoice-docs', (select path from t_fk));
select throws_ok($$ select api.attach_faktur((select id from t_fk), 'abc', (select path from t_fk)) $$, 'P0001', 'invalid:faktur_no',
                 'nomor faktur divalidasi');
select lives_ok($$ select api.attach_faktur((select id from t_fk), '010.000-26.00000001', (select path from t_fk)) $$,
                'regresi AB-4: admin_finance mencatat faktur pajak invoice lunas');
select throws_ok($$ select api.attach_faktur((select id from api.invoices where status = 'paid' and id <> (select id from t_fk) limit 1),
                                             '010.000-26.00000001', 'x') $$, 'P0001', 'faktur_used', 'satu nomor faktur untuk satu invoice');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
select is((select faktur_no || '|' || faktur_path from api.invoices where id = (select id from t_fk)),
          '010.000-26.00000001|' || (select path from t_fk), 'brand billing melihat nomor + berkas faktur');
select is((select count(*)::int from storage.objects where bucket_id = 'invoice-docs'), 1, 'brand billing bisa mengunduh PDF faktur');
select pg_temp.jwt('22222222-0000-0000-0000-0000000000d9');
select is((select count(*)::int from storage.objects where bucket_id = 'invoice-docs'), 0, 'bukan anggota billing org tidak bisa mengunduh');
select set_config('storage.allow_delete_query', 'true', true);  -- seperti Storage API (RLS tetap berlaku)
select pg_temp.jwt('22222222-0000-0000-0000-0000000000c1', '{"aal":"aal2"}');
delete from storage.objects where bucket_id = 'invoice-docs';
reset role;
insert into storage.objects (bucket_id, name) values ('invoice-docs', '44444444-0000-0000-0000-000000000001/orphan.pdf');
select is((select count(*)::int from storage.objects where bucket_id = 'invoice-docs'), 2, 'brand tidak bisa menghapus berkas faktur');
set local role authenticated;
select pg_temp.jwt('33333333-0000-0000-0000-0000000000f1', '{"app_roles":["admin_finance"],"aal":"aal2"}');
delete from storage.objects where bucket_id = 'invoice-docs' and name = '44444444-0000-0000-0000-000000000001/orphan.pdf';
reset role;
select is((select count(*)::int from storage.objects where bucket_id = 'invoice-docs'), 1,
          'regresi R24-3: admin_finance bisa membersihkan PDF yang ditolak/diganti');

-- Regresi audit 2 AB-7/AA-14 (§5.4 "reward non-tunai tetap punya nilai Rupiah, tetap tercatat untuk pajak"): rekap PPh 21
-- = payout tunai dibayar + reward non-tunai terkirim dinilai Rupiah.
create temp table t_pph as select * from api.bridge_pph21((now() at time zone 'Asia/Jakarta')::date - 1, (now() at time zone 'Asia/Jakarta')::date + 1);
select ok((select noncash >= 50000 from t_pph where user_id = (select user_id from finance.fulfillments where id = (select id from t_pay where k = 'f1'))),
          'regresi AB-7: voucher terkirim (1 × Rp50.000) masuk penghasilan bruto non-tunai');
select is((select count(*)::int from t_pph where gross <> cash + noncash), 0, 'bruto = tunai + non-tunai');
select is((select coalesce(sum(cash), 0) from t_pph), (select coalesce(sum(amount), 0) from finance.payouts where status = 'paid'), 'tunai = payout dibayar dalam periode');

-- Regresi audit 2 AA-5 (A3.7, R-18): instant processing ber-provider_ref yang callback-nya hilang dicek ulang (status di
-- penyedia, tanpa kirim ulang) dan memunculkan alert; sebelumnya hanya yang tanpa provider_ref yang diurus.
insert into finance.payouts (id, user_id, method_id, amount, fee, channel, idempotency_key, created_at) values
  ('abababab-0000-0000-0000-000000000001', '11111111-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-0000000000a1',
   100000, 5000, 'instant', 'aa5-hanging', now() - interval '2 hours');
update finance.payouts set status = 'processing', provider_ref = 'disb-hanging' where id = 'abababab-0000-0000-0000-000000000001';
delete from ops.alerts where kind = 'payout.instant_stuck';
select ok(finance.retry_instant_payouts() >= 1, 'regresi AA-5: instant processing ber-ref > 1 jam dikirim ke disburse (cek status)');
select ok(exists (select 1 from net.http_request_queue q where convert_from(q.body, 'UTF8')::jsonb ->> 'payout_id' = 'abababab-0000-0000-0000-000000000001'),
          'bridge disburse dipanggil untuk payout yang menggantung');
select ok(exists (select 1 from ops.alerts where kind = 'payout.instant_stuck' and resolved_at is null), 'instant menggantung → alert finance');
select is(api.bridge_get_payout('abababab-0000-0000-0000-000000000001') ->> 'provider_ref', 'disb-hanging',
          'identity menerima provider_ref untuk membaca status, bukan mengirim ulang');

-- ========== Invarian akhir ==========
select is((select count(*)::int from (select 1 from finance.ledger_entries e group by e.txn_id, e.reward_type_id having sum(e.amount) <> 0) x),
          0, 'akhir: ledger seimbang per transaksi per reward type');
select is((select count(*)::int from finance.reward_pools rp
            where rp.allocated <> coalesce((select -sum(e.amount) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                                            where a.owner_type = 'campaign_pool' and a.owner_id = rp.id
                                              and e.ref_type in ('accrual', 'reversal', 'release')), 0)), 0,
          'akhir: allocated = cache jurnal pool');
select is((select count(*)::int from finance.ledger_accounts a where a.owner_type = 'user_wallet'
            and (select coalesce(sum(e.amount), 0) from finance.ledger_entries e where e.account_id = a.id and e.state in ('pending', 'available')) < 0), 0,
          'akhir: tidak ada saldo pending/Tersedia negatif');
set constraints all immediate;
select pass('akhir: constraint trigger saldo seimbang lolos');

select * from finish();
rollback;
