-- Data awal core: reward type global, fee rule global, kategori, dan config default E-25. Idempoten (aman dijalankan ulang).
-- Lokal: dimuat `supabase db reset` (seed.sql). Staging/produksi: jalankan sekali di Fase 0 (psql -f), lalu
-- set auth.identity_issuer ke issuer dari discovery identity (PRD §15.6). Nilai di sini = default PRD; ubah lewat api.update_config.

insert into market.reward_types (code, name, kind, unit_label, idr_value_per_unit, decimals, fulfillment)
values ('IDR', 'Rupiah', 'cash', 'Rp', 1, 0, 'payout')
on conflict (owner_org_id, code) do nothing;

insert into finance.fee_rules (scope, mgmt_fee_pct, admin_fee_pct, clipper_fee_pct, instant_withdraw_fee)
select 'global', 15, 5, 0, 5000
where not exists (select 1 from finance.fee_rules where scope = 'global');

insert into market.categories (id, name_id, name_en, sort) values
  ('movies', 'Film', 'Movies', 1),
  ('games', 'Game', 'Games', 2),
  ('music', 'Musik', 'Music', 3),
  ('brand', 'Brand', 'Brand', 4),
  ('ugc', 'UGC', 'UGC', 5),
  ('podcast', 'Podcast', 'Podcast', 6)
on conflict (id) do nothing;

-- Registri config. public.* terbaca anon (policy settings_public_read); sisanya hanya admin & fungsi definer.
insert into ops.settings (key, value) values
  -- Lokal = issuer GoTrue stack identity (supabase start --workdir db/identity). Produksi: https://auth.{domain}/auth/v1
  ('auth.identity_issuer', '"http://127.0.0.1:54321/auth/v1"'),
  ('public.finance.min_withdraw_idr', '100000'),
  ('public.finance.instant_min_trust', '70'),
  ('public.market.max_accounts_per_platform', '3'),
  ('public.market.claim_hours', '48'),
  ('public.market.new_badge_days', '3'),
  ('public.billing.qris_max_idr', '10000000'),
  ('public.billing.tax_pct', '11'),
  ('public.billing.pin_price_per_week_idr', '500000'),
  ('public.billing.managed_service_idr', '2500000'),
  ('public.billing.invoice_due_days', '7'),
  ('public.billing.bank_account', '{"bank":"","number":"","name":""}'),
  ('public.billing.qris_payload', '""'),
  ('public.flags.instant_withdraw', 'false'),
  ('public.flags.ai_clip', 'false'),
  ('public.flags.platforms', '{"tiktok":true,"instagram":true,"youtube":true,"threads":false,"facebook":false,"x":false}'),
  ('public.community.links', '{"discord":"","whatsapp":""}'),
  ('public.ai_clip.url', '""'),
  ('public.home.banners', '[]'),
  ('public.finance.hold_days', '7'),
  -- §12 / C4.1: tier Trust Score → cap per klip & hold; TikTok (sinyal paling miskin) cap lebih rendah & hold lebih panjang.
  ('public.finance.trust_tiers', '[{"min_score":80,"cap_pct":120,"hold_days":3},{"min_score":60,"cap_pct":100,"hold_days":5}]'),
  ('public.finance.platform_rules', '{"tiktok":{"cap_pct":80,"hold_days":10}}'),
  ('finance.settlement_threshold_pct', '5'),
  ('finance.referral_bonus_pct', '5'),
  ('finance.referral_bonus_days', '90'),
  ('finance.settlement_wait_hours', '6'),
  ('public.finance.refund_transfer_fee_idr', '2500'),
  ('tracking.final_grace_hours', '72'),
  ('trust.fraud.lock_drop_pct', '20'),
  ('trust.fraud.min_avg_watch_sec', '3'),
  ('trust.fraud.max_skip_rate', '80'),
  ('trust.fraud.min_id_country_share', '0.5'),
  ('public.market.brand_review_auto_approve_hours', '72'),
  ('trust.score_deltas', '{"submission_approved":1,"submission_rejected":-2,"appeal_failed":-3}'),
  ('tracking.poll_schedule', '[{"until_hours":72,"every_hours":4},{"until_hours":336,"every_hours":24},{"until_hours":null,"every_hours":72}]'),
  ('trust.fraud.like_rate_min', '0.005'),
  ('trust.fraud.spike_multiplier', '10'),
  ('trust.fraud.new_account_days', '14'),
  ('trust.fraud.new_account_views', '100000'),
  ('trust.fraud.views_over_reach', '3'),
  ('trust.fraud.flag_spike_per_hour', '20')
on conflict (key) do nothing;
