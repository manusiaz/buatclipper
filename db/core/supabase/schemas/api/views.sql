-- View yang dibaca browser (Data API hanya mengekspos schema api). Semua security_invoker: hak kolom & RLS tabel dasar
-- berlaku untuk pemanggil, jadi satu view melayani anon, clipper, anggota brand, dan admin dengan baris berbeda.
-- Wajib engine pg-delta: engine migra membuang security_invoker dari definisi view (docs declarative schemas).

-- Publik (anon + login)
create view api.campaigns with (security_invoker = true) as
  select id, org_id, slug, title, type, category_id, status, platforms, brief, required_hashtags, required_mentions,
         required_links, sponsored_label, min_duration_sec, max_duration_sec, dos, donts, example_urls, faq, service_mode,
         start_at, submit_deadline, view_window_days,
         review_mode, min_followers, min_account_age_days, min_trust_score, kyc_required, min_views, max_clips_per_clipper,
         clipper_quota, allow_video_reuse, visibility, is_template, pinned_until, pinned_rank, fee_rule_id, created_at
  from market.campaigns;
create view api.campaign_assets with (security_invoker = true) as
  select id, campaign_id, kind, storage_path, url, size_bytes, audience, created_at from market.campaign_assets;
create view api.rate_rules with (security_invoker = true) as
  select id, campaign_id, kind, reward_type_id, pool_id, platform, params, effective_from, effective_to, lineage_id from market.rate_rules;
create view api.reward_types with (security_invoker = true) as
  select id, owner_org_id, code, name, kind, unit_label, idr_value_per_unit, decimals, fulfillment, recipient_schema, stock
  from market.reward_types;
create view api.reward_pools with (security_invoker = true) as
  select id, campaign_id, reward_type_id, total, allocated, total - allocated as remaining, max_per_clip from finance.reward_pools;
create view api.categories with (security_invoker = true) as
  select id, name_id, name_en, sort, active from market.categories;
create view api.profiles with (security_invoker = true) as
  select id, username, display_name, avatar_path, created_at from market.profiles;
create view api.settings with (security_invoker = true) as
  select key, value, updated_at from ops.settings;
grant select on api.campaigns, api.campaign_assets, api.rate_rules, api.reward_types, api.reward_pools, api.categories,
                api.profiles, api.settings to anon, authenticated;

-- Login (baris dibatasi RLS: milik sendiri / anggota org / admin)
create view api.my_profile with (security_invoker = true) as
  select id, username, display_name, avatar_path, trust_score, status, suspended_until, created_at
  from market.profiles where id = (select auth.uid());
-- Paket managed (J-A7): brief mentah brand untuk anggota org pemilik & admin; api.campaigns publik tidak membawanya.
create view api.managed_briefs with (security_invoker = true) as
  select c.id as campaign_id, c.managed_brief from market.campaigns c
  where c.service_mode = 'managed' and ((select ops.is_org_member(c.org_id)) or (select ops.has_admin()));
-- Admin (F-A07): status & Trust Score semua clipper. Baris kosong untuk non-admin.
create view api.admin_profiles with (security_invoker = true) as
  select id, username, display_name, avatar_path, trust_score, status, suspended_until, created_at
  from market.profiles where (select ops.has_admin());
create view api.organizations with (security_invoker = true) as
  select id, name, org_type, legal_name, npwp, address, is_agency, fee_rule_id, status, verified_at, created_at, updated_at from market.organizations;
create view api.org_members with (security_invoker = true) as
  select org_id, user_id, role, created_at from market.org_members;
create view api.claims with (security_invoker = true) as
  select id, campaign_id, user_id, status, expires_at, created_at from market.claims;
create view api.social_accounts with (security_invoker = true) as
  select id, user_id, platform, external_id, handle, status, followers, platform_created_at, verified_at, created_at
  from tracking.social_accounts;
create view api.submissions with (security_invoker = true) as
  select id, claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at, status, counted_views,
         last_snapshot_at, last_views, locked_at, created_at
  from tracking.submissions;
create view api.view_snapshots with (security_invoker = true) as
  select id, submission_id, taken_at, views, likes, comments, shares, is_final from tracking.view_snapshots;
create view api.review_decisions with (security_invoker = true) as
  select id, target_type, target_id, actor_id, decision, reason_code, message, created_at from trust.review_decisions;
create view api.fraud_flags with (security_invoker = true) as
  select id, target_type, target_id, signal, score, status, details, resolved_by, resolved_at, created_at from trust.fraud_flags;
create view api.notifications with (security_invoker = true) as
  select id, user_id, event, payload, read_at, created_at from ops.notifications where in_app;
create view api.notification_prefs with (security_invoker = true) as
  select user_id, email_promotions, updated_at from ops.notification_prefs;
create view api.audit_logs with (security_invoker = true) as
  select id, actor_id, action, target, before, after, at from ops.audit_logs;
create view api.report_links with (security_invoker = true) as
  select id, campaign_id, created_by, expires_at, revoked_at, created_at from market.report_links;
create view api.fee_rules with (security_invoker = true) as
  select id, scope, mgmt_fee_pct, admin_fee_pct, clipper_fee_pct, instant_withdraw_fee from finance.fee_rules;
create view api.wallet_balances with (security_invoker = true) as
  select a.owner_id as user_id, e.reward_type_id, e.state, sum(e.amount) as amount
  from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
  where a.owner_type = 'user_wallet'
  group by a.owner_id, e.reward_type_id, e.state;
create view api.wallet_entries with (security_invoker = true) as
  select e.id, a.owner_id as user_id, e.reward_type_id, e.amount, e.state, e.ref_type, e.ref_id, e.created_at
  from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
  where a.owner_type = 'user_wallet';
-- F-A08 ledger untuk back-office finance: entri + pemilik akun, hanya admin_finance (baris kosong untuk yang lain).
create view api.admin_ledger with (security_invoker = true) as
  select e.id, e.txn_id, e.created_at, a.owner_type, a.owner_id, rt.code as reward_type, e.amount, e.state, e.ref_type, e.ref_id
  from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
  join market.reward_types rt on rt.id = e.reward_type_id
  where (select ops.has_admin('admin_finance'));
create view api.payouts with (security_invoker = true) as
  select id, user_id, method_id, batch_id, channel, amount, fee, status, hold_reason, bank_ref, provider_ref, last_error, created_at,
         paid_at
  from finance.payouts;
create view api.fulfillments with (security_invoker = true) as
  select id, user_id, reward_type_id, amount, recipient, status, delivered_ref, attempts, created_at, delivered_at, next_retry_at
  from finance.fulfillments;
-- Admin (A5.1): CSV penerima yang sudah diserahkan ke brand; pending = klaim yang masih menunggu kiriman brand (unduh ulang).
create view api.fulfillment_exports with (security_invoker = true) as
  select f.reward_type_id, f.export_ref as file_ref, count(*)::int as rows,
         (count(*) filter (where f.status = 'processing'))::int as pending
  from finance.fulfillments f where f.export_ref is not null and (select ops.has_admin())
  group by f.reward_type_id, f.export_ref;
create view api.invoices with (security_invoker = true) as
  select id, number, org_id, campaign_id, kind, subtotal, mgmt_fee, admin_fee, service_fee, tax, total, status, payment_channel,
         paid_amount, paid_at, faktur_no, faktur_path, issued_at, due_at, pin_until, pool_topups, credit_applied, fee_exempt,
         total - credit_applied as amount_due  -- yang ditagih lewat transfer/QRIS setelah kredit org
  from finance.invoices;
create view api.org_refunds with (security_invoker = true) as
  select id, org_id, campaign_id, amount, transfer_fee, status, requested_by, created_at, paid_at, bank_ref, dest_bank, dest_account,
         dest_name, dest_set_by from finance.org_refunds;
create view api.payout_batches with (security_invoker = true) as
  select id, created_by, approved_by, status, cutoff_at, total, count, executed_at, created_at from finance.payout_batches;

create view api.campaign_invites with (security_invoker = true) as
  select campaign_id, user_id, invited_by, created_at from market.campaign_invites;
create view api.org_links with (security_invoker = true) as
  select agency_org_id, client_org_id, approved_by, approved_at, revoked_at, created_at from market.org_links;
create view api.referrals with (security_invoker = true) as
  select r.referred_id, p.username as referred_username, r.qualified_at, r.bonus_until, r.created_at
  from market.referrals r join market.profiles p on p.id = r.referred_id;
create view api.score_events with (security_invoker = true) as
  select id, user_id, delta, reason, created_at from trust.score_events;
create view api.reward_codes with (security_invoker = true) as
  select id, reward_type_id, code, fulfillment_id, created_at, assigned_at from finance.reward_codes;
create view api.broadcasts with (security_invoker = true) as
  select id, title, body, segment, channels, created_by, scheduled_at, sent_at, recipient_count, kind from ops.broadcasts;
create view api.leaderboard with (security_invoker = true) as
  select 'week'::text as scope, w.week_start, null::uuid as campaign_id, w.user_id, p.username, p.avatar_path, w.views, w.rank
  from market.leaderboard_weekly w join market.profiles p on p.id = w.user_id
  union all
  select 'campaign', null, c.campaign_id, c.user_id, p.username, p.avatar_path, c.views, c.rank
  from market.leaderboard_campaign c join market.profiles p on p.id = c.user_id
  where exists (select 1 from market.campaigns k where k.id = c.campaign_id);

grant select on api.my_profile, api.admin_profiles, api.managed_briefs, api.organizations, api.org_members, api.claims, api.social_accounts,
                api.submissions, api.view_snapshots, api.review_decisions, api.fraud_flags, api.notifications,
                api.notification_prefs, api.audit_logs, api.report_links, api.fee_rules, api.wallet_balances,
                api.wallet_entries, api.admin_ledger, api.payouts, api.fulfillments, api.fulfillment_exports, api.invoices, api.org_refunds, api.payout_batches,
                api.campaign_invites, api.org_links, api.referrals, api.score_events, api.reward_codes, api.broadcasts,
                api.leaderboard
  to authenticated;
grant select on api.fee_rules to anon;
grant update (read_at) on api.notifications to authenticated;
grant insert (user_id, email_promotions), update (email_promotions, updated_at) on api.notification_prefs to authenticated;
-- §12 sanksi & bandingnya: clipper melihat miliknya (RLS), admin_moderator/admin_support semua.
create view api.sanctions with (security_invoker = true) as
  select id, user_id, kind, flag_id, reason, created_at, until, lifted_at, appeal_message, appealed_at, decision, decision_note, decided_at
  from trust.sanctions;
grant select on api.sanctions to authenticated;
