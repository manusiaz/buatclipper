SET local check_function_bodies = off;

CREATE SCHEMA "api";

CREATE SCHEMA "finance";

CREATE SCHEMA "market";

CREATE SCHEMA "ops";

CREATE SCHEMA "tracking";

CREATE SCHEMA "trust";

CREATE EXTENSION IF NOT EXISTS "pg_cron";

CREATE EXTENSION IF NOT EXISTS "pg_net" SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgmq";

CREATE SEQUENCE "finance"."invoice_number_seq" AS bigint INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1 NO CYCLE;

CREATE TABLE "finance"."clip_earnings" (
  "submission_id"   uuid                     NOT NULL,
  "rule_id"         uuid                     NOT NULL,
  "pool_id"         uuid                     NOT NULL,
  "amount"          numeric(30,10)           NOT NULL DEFAULT 0,
  "demand"          numeric(30,10)           NOT NULL DEFAULT 0,
  "demand_snapshot" bigint,
  "views_from"      bigint,
  "views_to"        bigint,
  "once_paid"       boolean                  NOT NULL DEFAULT false,
  "released_at"     timestamp with time zone,
  "updated_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "clip_earnings_amount_check" CHECK ((amount >= (0)::numeric)),
  CONSTRAINT "clip_earnings_demand_check" CHECK ((demand >= (0)::numeric)),
  CONSTRAINT "clip_earnings_demand_has_snapshot" CHECK (((demand = (0)::numeric) OR (demand_snapshot IS NOT NULL))),
  CONSTRAINT "clip_earnings_pkey" PRIMARY KEY (submission_id, rule_id),
  CONSTRAINT "clip_earnings_views_from_check" CHECK ((views_from >= 0)),
  CONSTRAINT "clip_earnings_views_range" CHECK (((views_to IS NULL) OR (views_from IS NULL) OR (views_to >= views_from)))
);

ALTER TABLE "finance"."clip_earnings"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "finance"."fee_rules" (
  "id"                   uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "scope"                text                     NOT NULL,
  "mgmt_fee_pct"         numeric(5,2)             NOT NULL DEFAULT 15,
  "admin_fee_pct"        numeric(5,2)             NOT NULL DEFAULT 5,
  "clipper_fee_pct"      numeric(5,2)             NOT NULL DEFAULT 0,
  "instant_withdraw_fee" numeric(18,2),
  "created_by"           uuid,
  "created_at"           timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "fee_rules_admin_fee_pct_check" CHECK (((admin_fee_pct >= (0)::numeric) AND (admin_fee_pct <= (100)::numeric))),
  CONSTRAINT "fee_rules_clipper_fee_pct_check" CHECK (((clipper_fee_pct >= (0)::numeric) AND (clipper_fee_pct <= (100)::numeric))),
  CONSTRAINT "fee_rules_instant_withdraw_fee_check" CHECK ((instant_withdraw_fee >= (0)::numeric)),
  CONSTRAINT "fee_rules_mgmt_fee_pct_check" CHECK (((mgmt_fee_pct >= (0)::numeric) AND (mgmt_fee_pct <= (100)::numeric))),
  CONSTRAINT "fee_rules_pkey" PRIMARY KEY (id),
  CONSTRAINT "fee_rules_scope_check" CHECK ((scope = ANY (ARRAY['global'::text, 'org'::text, 'campaign'::text])))
);

ALTER TABLE "finance"."fee_rules"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "finance"."fulfillments" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"         uuid                     NOT NULL,
  "reward_type_id"  uuid                     NOT NULL,
  "amount"          numeric(30,10)           NOT NULL,
  "recipient"       jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "recipient_ref"   uuid,
  "delivered_ref"   text,
  "attempts"        smallint                 NOT NULL DEFAULT 0,
  "last_error"      text,
  "next_retry_at"   timestamp with time zone,
  "idempotency_key" text                     NOT NULL,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "delivered_at"    timestamp with time zone,
  CONSTRAINT "fulfillments_amount_check" CHECK ((amount > (0)::numeric)),
  CONSTRAINT "fulfillments_attempts_check" CHECK ((attempts >= 0)),
  CONSTRAINT "fulfillments_idempotency_unique" UNIQUE (idempotency_key),
  CONSTRAINT "fulfillments_pkey" PRIMARY KEY (id),
  CONSTRAINT "fulfillments_recipient_check" CHECK ((jsonb_typeof(recipient) = 'object'::text))
);

ALTER TABLE "finance"."fulfillments"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "finance"."invoices" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "number"          text                     NOT NULL,
  "org_id"          uuid                     NOT NULL,
  "campaign_id"     uuid,
  "kind"            text                     NOT NULL DEFAULT 'campaign'::text,
  "subtotal"        numeric(18,2)            NOT NULL,
  "mgmt_fee"        numeric(18,2)            NOT NULL,
  "admin_fee"       numeric(18,2)            NOT NULL,
  "service_fee"     numeric(18,2)            NOT NULL DEFAULT 0,
  "tax"             numeric(18,2)            NOT NULL DEFAULT 0,
  "total"           numeric(18,2)            NOT NULL,
  "status"          text                     NOT NULL DEFAULT 'issued'::text,
  "payment_channel" text,
  "payment_ref"     text,
  "paid_amount"     numeric(18,2),
  "paid_at"         timestamp with time zone,
  "confirmed_by"    uuid,
  "faktur_no"       text,
  "issued_at"       timestamp with time zone NOT NULL DEFAULT now(),
  "due_at"          timestamp with time zone,
  "pin_until"       timestamp with time zone,
  "pool_topups"     jsonb,
  CONSTRAINT "invoices_admin_fee_check" CHECK ((admin_fee >= (0)::numeric)),
  CONSTRAINT "invoices_campaign_kinds" CHECK (((kind <> ALL (ARRAY['campaign'::text, 'topup'::text, 'pinned'::text])) OR (campaign_id IS NOT NULL))),
  CONSTRAINT "invoices_faktur_unique" UNIQUE (faktur_no),
  CONSTRAINT "invoices_kind_check" CHECK ((kind = ANY (ARRAY['campaign'::text, 'topup'::text, 'pinned'::text, 'managed_service'::text]))),
  CONSTRAINT "invoices_mgmt_fee_check" CHECK ((mgmt_fee >= (0)::numeric)),
  CONSTRAINT "invoices_number_unique" UNIQUE (number),
  CONSTRAINT "invoices_paid_amount_check" CHECK ((paid_amount > (0)::numeric)),
  CONSTRAINT "invoices_paid_complete" CHECK (((status <> 'paid'::text) OR ((payment_ref IS NOT NULL) AND (paid_amount IS NOT NULL) AND (paid_at IS NOT NULL) AND (confirmed_by IS
    NOT NULL) AND (payment_channel IS NOT NULL)))),
  CONSTRAINT "invoices_payment_channel_check" CHECK ((payment_channel = ANY (ARRAY['qris'::text, 'transfer'::text]))),
  CONSTRAINT "invoices_payment_ref_unique" UNIQUE (payment_ref),
  CONSTRAINT "invoices_pinned_has_period" CHECK (((kind = 'pinned'::text) = (pin_until IS NOT NULL))),
  CONSTRAINT "invoices_pkey" PRIMARY KEY (id),
  CONSTRAINT "invoices_service_fee_check" CHECK ((service_fee >= (0)::numeric)),
  CONSTRAINT "invoices_status_check" CHECK ((status = ANY (ARRAY['issued'::text, 'paid'::text, 'void'::text]))),
  CONSTRAINT "invoices_subtotal_check" CHECK ((subtotal >= (0)::numeric)),
  CONSTRAINT "invoices_tax_check" CHECK ((tax >= (0)::numeric)),
  CONSTRAINT "invoices_topup_has_pools" CHECK (((kind = 'topup'::text) = COALESCE((jsonb_typeof(pool_topups) = 'array'::text), false))),
  CONSTRAINT "invoices_total_consistent" CHECK ((total = ((((subtotal + mgmt_fee) + admin_fee) + service_fee) + tax)))
);

ALTER TABLE "finance"."invoices"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "finance"."ledger_accounts" (
  "id"             uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "owner_type"     text                     NOT NULL,
  "owner_id"       uuid,
  "reward_type_id" uuid                     NOT NULL,
  "created_at"     timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "ledger_accounts_key" UNIQUE (id, reward_type_id),
  CONSTRAINT "ledger_accounts_one_per_owner" UNIQUE NULLS NOT DISTINCT (owner_type, owner_id, reward_type_id),
  CONSTRAINT "ledger_accounts_owner_type_check"
    CHECK ((owner_type = ANY (ARRAY['user_wallet'::text, 'campaign_pool'::text, 'org_credit'::text, 'platform_revenue'::text, 'bank_clearing'::text, 'tax_payable'::text]))),
  CONSTRAINT "ledger_accounts_owner" CHECK (((owner_type = ANY (ARRAY['platform_revenue'::text, 'bank_clearing'::text, 'tax_payable'::text])) = (owner_id IS NULL))),
  CONSTRAINT "ledger_accounts_pkey" PRIMARY KEY (id)
);

ALTER TABLE "finance"."ledger_accounts"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "finance"."ledger_entries" (
  "id"             bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "txn_id"         uuid                     NOT NULL,
  "account_id"     uuid                     NOT NULL,
  "reward_type_id" uuid                     NOT NULL,
  "amount"         numeric(30,10)           NOT NULL,
  "ref_type"       text                     NOT NULL,
  "ref_id"         text                     NOT NULL,
  "created_at"     timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "ledger_entries_amount_check" CHECK ((amount <> (0)::numeric)),
  CONSTRAINT "ledger_entries_pkey" PRIMARY KEY (id),
  CONSTRAINT "ledger_entries_ref_type_check"
    CHECK
    ((ref_type = ANY (ARRAY['accrual'::text, 'release'::text, 'reversal'::text, 'payout'::text, 'payout_return'::text, 'invoice_payment'::text, 'fee'::text, 'refund'::text,
    'rollover'::text, 'fulfillment'::text, 'referral_bonus'::text, 'adjustment'::text])))
);

ALTER TABLE "finance"."ledger_entries"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "finance"."org_refunds" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "org_id"          uuid                     NOT NULL,
  "campaign_id"     uuid,
  "amount"          numeric(18,2)            NOT NULL,
  "transfer_fee"    numeric(18,2)            NOT NULL DEFAULT 0,
  "status"          text                     NOT NULL DEFAULT 'requested'::text,
  "requested_by"    uuid                     NOT NULL,
  "approved_by"     uuid,
  "bank_ref"        text,
  "proof_ref"       text,
  "idempotency_key" text                     NOT NULL,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "paid_at"         timestamp with time zone,
  CONSTRAINT "org_refunds_amount_check" CHECK ((amount > (0)::numeric)),
  CONSTRAINT "org_refunds_approved" CHECK (((status <> ALL (ARRAY['approved'::text, 'paid'::text])) OR (approved_by IS NOT NULL))),
  CONSTRAINT "org_refunds_fee_below_amount" CHECK ((transfer_fee < amount)),
  CONSTRAINT "org_refunds_idempotency_unique" UNIQUE (idempotency_key),
  CONSTRAINT "org_refunds_paid_complete" CHECK (((status <> 'paid'::text) OR ((paid_at IS NOT NULL) AND (proof_ref IS NOT NULL)))),
  CONSTRAINT "org_refunds_pkey" PRIMARY KEY (id),
  CONSTRAINT "org_refunds_status_check" CHECK ((status = ANY (ARRAY['requested'::text, 'approved'::text, 'paid'::text, 'cancelled'::text]))),
  CONSTRAINT "org_refunds_transfer_fee_check" CHECK ((transfer_fee >= (0)::numeric)),
  CONSTRAINT "org_refunds_two_person" CHECK (((approved_by IS NULL) OR (approved_by <> requested_by)))
);

ALTER TABLE "finance"."org_refunds"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "finance"."payout_batches" (
  "id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "created_by"  uuid                     NOT NULL,
  "approved_by" uuid,
  "status"      text                     NOT NULL DEFAULT 'draft'::text,
  "cutoff_at"   timestamp with time zone NOT NULL,
  "total"       numeric(18,2)            NOT NULL DEFAULT 0,
  "count"       integer                  NOT NULL DEFAULT 0,
  "file_ref"    text,
  "executed_at" timestamp with time zone,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "payout_batches_approved" CHECK (((status = 'draft'::text) OR (approved_by IS NOT NULL))),
  CONSTRAINT "payout_batches_count_check" CHECK ((count >= 0)),
  CONSTRAINT "payout_batches_exported_has_file" CHECK (((status <> ALL (ARRAY['exported'::text, 'paid'::text, 'closed'::text])) OR (file_ref IS NOT NULL))),
  CONSTRAINT "payout_batches_pkey" PRIMARY KEY (id),
  CONSTRAINT "payout_batches_status_check" CHECK ((status = ANY (ARRAY['draft'::text, 'approved'::text, 'exported'::text, 'paid'::text, 'closed'::text]))),
  CONSTRAINT "payout_batches_total_check" CHECK ((total >= (0)::numeric)),
  CONSTRAINT "payout_batches_two_person" CHECK (((approved_by IS NULL) OR (approved_by <> created_by)))
);

ALTER TABLE "finance"."payout_batches"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "finance"."payouts" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"         uuid                     NOT NULL,
  "method_id"       uuid                     NOT NULL,
  "batch_id"        uuid,
  "amount"          numeric(18,2)            NOT NULL,
  "fee"             numeric(18,2)            NOT NULL DEFAULT 0,
  "channel"         text                     NOT NULL DEFAULT 'batch'::text,
  "hold_reason"     text,
  "bank_ref"        text,
  "proof_ref"       text,
  "provider_ref"    text,
  "idempotency_key" text                     NOT NULL,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "paid_at"         timestamp with time zone,
  CONSTRAINT "payouts_amount_check" CHECK ((amount > (0)::numeric)),
  CONSTRAINT "payouts_channel_check" CHECK ((channel = ANY (ARRAY['batch'::text, 'instant'::text]))),
  CONSTRAINT "payouts_fee_below_amount" CHECK ((fee < amount)),
  CONSTRAINT "payouts_fee_check" CHECK ((fee >= (0)::numeric)),
  CONSTRAINT "payouts_idempotency_unique" UNIQUE (idempotency_key),
  CONSTRAINT "payouts_instant_no_batch" CHECK (((channel = 'batch'::text) OR (batch_id IS NULL))),
  CONSTRAINT "payouts_pkey" PRIMARY KEY (id),
  CONSTRAINT "payouts_provider_ref_unique" UNIQUE (provider_ref)
);

ALTER TABLE "finance"."payouts"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "finance"."pool_settlements" (
  "pool_id"    uuid                     NOT NULL,
  "cutoff_at"  timestamp with time zone NOT NULL DEFAULT now(),
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "pool_settlements_pkey" PRIMARY KEY (pool_id)
);

ALTER TABLE "finance"."pool_settlements"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "finance"."reward_codes" (
  "id"             uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "reward_type_id" uuid                     NOT NULL,
  "code"           text                     NOT NULL,
  "fulfillment_id" uuid,
  "uploaded_by"    uuid                     NOT NULL,
  "created_at"     timestamp with time zone NOT NULL DEFAULT now(),
  "assigned_at"    timestamp with time zone,
  CONSTRAINT "reward_codes_assignment_complete" CHECK (((fulfillment_id IS NULL) = (assigned_at IS NULL))),
  CONSTRAINT "reward_codes_one_per_fulfillment" UNIQUE (fulfillment_id),
  CONSTRAINT "reward_codes_pkey" PRIMARY KEY (id),
  CONSTRAINT "reward_codes_unique" UNIQUE (reward_type_id, code)
);

ALTER TABLE "finance"."reward_codes"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "finance"."reward_pools" (
  "id"             uuid           NOT NULL DEFAULT gen_random_uuid(),
  "campaign_id"    uuid           NOT NULL,
  "reward_type_id" uuid           NOT NULL,
  "total"          numeric(30,10) NOT NULL,
  "allocated"      numeric(30,10) NOT NULL DEFAULT 0,
  "max_per_clip"   numeric(30,10) NOT NULL,
  CONSTRAINT "reward_pools_allocated_range" CHECK (((allocated >= (0)::numeric) AND (allocated <= total))),
  CONSTRAINT "reward_pools_key" UNIQUE (id, campaign_id, reward_type_id),
  CONSTRAINT "reward_pools_max_per_clip_check" CHECK ((max_per_clip > (0)::numeric)),
  CONSTRAINT "reward_pools_pkey" PRIMARY KEY (id),
  CONSTRAINT "reward_pools_total_check" CHECK ((total > (0)::numeric))
);

ALTER TABLE "finance"."reward_pools"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."budget_alerts" (
  "campaign_id"     uuid                     NOT NULL,
  "kind"            text                     NOT NULL,
  "utilization_pct" numeric(7,2),
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "budget_alerts_kind_check" CHECK ((kind = ANY (ARRAY['used_50'::text, 'used_80'::text, 'used_100'::text, 'projection_low'::text]))),
  CONSTRAINT "budget_alerts_pkey" PRIMARY KEY (campaign_id, kind)
);

ALTER TABLE "market"."budget_alerts"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."campaign_assets" (
  "id"           uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "campaign_id"  uuid                     NOT NULL,
  "kind"         text                     NOT NULL,
  "storage_path" text,
  "url"          text,
  "size_bytes"   bigint,
  "audience"     text                     NOT NULL DEFAULT 'clipper'::text,
  "created_at"   timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "campaign_assets_audience_check" CHECK ((audience = ANY (ARRAY['clipper'::text, 'internal'::text]))),
  CONSTRAINT "campaign_assets_cover_public" CHECK (((kind <> 'cover'::text) OR (audience = 'clipper'::text))),
  CONSTRAINT "campaign_assets_internal_folder" CHECK (((storage_path IS NULL) OR ((split_part(storage_path, '/'::text, 3) = 'internal'::text) = (audience = 'internal'::text)))),
  CONSTRAINT "campaign_assets_kind_check" CHECK ((kind = ANY (ARRAY['cover'::text, 'video'::text, 'image'::text, 'audio'::text, 'document'::text, 'link'::text]))),
  CONSTRAINT "campaign_assets_link_is_url" CHECK (((kind = 'link'::text) = (url IS NOT NULL))),
  CONSTRAINT "campaign_assets_one_source" CHECK (((storage_path IS NULL) <> (url IS NULL))),
  CONSTRAINT "campaign_assets_pkey" PRIMARY KEY (id),
  CONSTRAINT "campaign_assets_size_bytes_check" CHECK ((size_bytes >= 0)),
  CONSTRAINT "campaign_assets_url_check" CHECK ((url ~ '^https://'::text))
);

ALTER TABLE "market"."campaign_assets"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."campaign_invites" (
  "campaign_id" uuid                     NOT NULL,
  "user_id"     uuid                     NOT NULL,
  "invited_by"  uuid                     NOT NULL,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "campaign_invites_pkey" PRIMARY KEY (campaign_id, user_id)
);

ALTER TABLE "market"."campaign_invites"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."campaigns" (
  "id"                    uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "org_id"                uuid                     NOT NULL,
  "slug"                  text                     NOT NULL,
  "title"                 text                     NOT NULL,
  "type"                  text                     NOT NULL,
  "category_id"           text,
  "brief"                 text                     NOT NULL DEFAULT ''::text,
  "required_hashtags"     text[]                   NOT NULL DEFAULT '{}'::text[],
  "required_mentions"     text[]                   NOT NULL DEFAULT '{}'::text[],
  "required_links"        text[]                   NOT NULL DEFAULT '{}'::text[],
  "sponsored_label"       boolean                  NOT NULL DEFAULT true,
  "min_duration_sec"      smallint,
  "max_duration_sec"      smallint,
  "dos"                   text[]                   NOT NULL DEFAULT '{}'::text[],
  "donts"                 text[]                   NOT NULL DEFAULT '{}'::text[],
  "example_urls"          text[]                   NOT NULL DEFAULT '{}'::text[],
  "faq"                   jsonb                    NOT NULL DEFAULT '[]'::jsonb,
  "service_mode"          text                     NOT NULL DEFAULT 'self_serve'::text,
  "start_at"              timestamp with time zone,
  "submit_deadline"       timestamp with time zone,
  "view_window_days"      smallint                 NOT NULL DEFAULT 30,
  "review_mode"           text                     NOT NULL DEFAULT 'manual'::text,
  "min_followers"         integer                  NOT NULL DEFAULT 0,
  "min_account_age_days"  smallint                 NOT NULL DEFAULT 0,
  "min_trust_score"       smallint                 NOT NULL DEFAULT 0,
  "kyc_required"          boolean                  NOT NULL DEFAULT false,
  "min_views"             integer                  NOT NULL DEFAULT 1000,
  "max_clips_per_clipper" smallint                 NOT NULL DEFAULT 10,
  "clipper_quota"         integer,
  "allow_video_reuse"     boolean                  NOT NULL DEFAULT false,
  "visibility"            text                     NOT NULL DEFAULT 'public'::text,
  "is_template"           boolean                  NOT NULL DEFAULT false,
  "fee_rule_id"           uuid,
  "pinned_until"          timestamp with time zone,
  "pinned_rank"           smallint,
  "created_by"            uuid                     NOT NULL,
  "created_at"            timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "campaigns_clipper_quota_check" CHECK ((clipper_quota >= 1)),
  CONSTRAINT "campaigns_duration_range" CHECK (((min_duration_sec IS NULL) OR (max_duration_sec IS NULL) OR (min_duration_sec <= max_duration_sec))),
  CONSTRAINT "campaigns_examples_https"
    CHECK
    (((array_position(example_urls, NULL::text) IS NULL) AND ((cardinality(example_urls) = 0) OR (array_to_string(example_urls, ' '::text) ~
    '^https://\S+( https://\S+)*$'::text)))),
  CONSTRAINT "campaigns_faq_check" CHECK ((jsonb_typeof(faq) = 'array'::text)),
  CONSTRAINT "campaigns_hashtags_format"
    CHECK
    (((array_position(required_hashtags, NULL::text) IS NULL) AND ((cardinality(required_hashtags) = 0) OR (array_to_string(required_hashtags, ','::text) ~
    '^[[:lower:][:digit:]_]+(,[[:lower:][:digit:]_]+)*$'::text)))),
  CONSTRAINT "campaigns_level_has_threshold" CHECK (((visibility <> 'level'::text) OR (min_trust_score > 0))),
  CONSTRAINT "campaigns_links_https"
    CHECK
    (((array_position(required_links, NULL::text) IS NULL) AND ((cardinality(required_links) = 0) OR (array_to_string(required_links, ' '::text) ~
    '^https://\S+( https://\S+)*$'::text)))),
  CONSTRAINT "campaigns_max_clips_per_clipper_check" CHECK ((max_clips_per_clipper >= 1)),
  CONSTRAINT "campaigns_max_duration_sec_check" CHECK ((max_duration_sec > 0)),
  CONSTRAINT "campaigns_mentions_format"
    CHECK
    (((array_position(required_mentions, NULL::text) IS NULL) AND ((cardinality(required_mentions) = 0) OR (array_to_string(required_mentions, ','::text) ~
    '^[[:lower:][:digit:]_.]+(,[[:lower:][:digit:]_.]+)*$'::text)))),
  CONSTRAINT "campaigns_min_account_age_days_check" CHECK ((min_account_age_days >= 0)),
  CONSTRAINT "campaigns_min_duration_sec_check" CHECK ((min_duration_sec > 0)),
  CONSTRAINT "campaigns_min_followers_check" CHECK ((min_followers >= 0)),
  CONSTRAINT "campaigns_min_trust_score_check" CHECK (((min_trust_score >= 0) AND (min_trust_score <= 100))),
  CONSTRAINT "campaigns_min_views_check" CHECK ((min_views >= 0)),
  CONSTRAINT "campaigns_pinned_rank_check" CHECK ((pinned_rank >= 1)),
  CONSTRAINT "campaigns_pkey" PRIMARY KEY (id),
  CONSTRAINT "campaigns_review_mode_check" CHECK ((review_mode = ANY (ARRAY['auto'::text, 'manual'::text, 'brand'::text]))),
  CONSTRAINT "campaigns_schedule" CHECK (((submit_deadline IS NULL) OR (start_at IS NULL) OR (submit_deadline > start_at))),
  CONSTRAINT "campaigns_service_mode_check" CHECK ((service_mode = ANY (ARRAY['self_serve'::text, 'managed'::text]))),
  CONSTRAINT "campaigns_slug_check" CHECK ((slug ~ '^[a-z0-9-]{3,80}$'::text)),
  CONSTRAINT "campaigns_slug_unique" UNIQUE (slug),
  CONSTRAINT "campaigns_title_check" CHECK (((char_length(title) >= 3) AND (char_length(title) <= 120))),
  CONSTRAINT "campaigns_type_check" CHECK ((type = ANY (ARRAY['clipping'::text, 'ugc'::text, 'music'::text, 'logo'::text, 'text'::text]))),
  CONSTRAINT "campaigns_view_window_days_check" CHECK (((view_window_days >= 1) AND (view_window_days <= 90))),
  CONSTRAINT "campaigns_visibility_check" CHECK ((visibility = ANY (ARRAY['public'::text, 'invite'::text, 'level'::text])))
);

ALTER TABLE "market"."campaigns"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."categories" (
  "id"      text     NOT NULL,
  "name_id" text     NOT NULL,
  "name_en" text     NOT NULL,
  "sort"    smallint NOT NULL DEFAULT 0,
  "active"  boolean  NOT NULL DEFAULT true,
  CONSTRAINT "categories_id_check" CHECK ((id ~ '^[a-z0-9-]{2,30}$'::text)),
  CONSTRAINT "categories_pkey" PRIMARY KEY (id)
);

ALTER TABLE "market"."categories"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."claims" (
  "id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "campaign_id" uuid                     NOT NULL,
  "user_id"     uuid                     NOT NULL,
  "expires_at"  timestamp with time zone NOT NULL,
  "reminded_at" timestamp with time zone,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "claims_expiry" CHECK ((expires_at > created_at)),
  CONSTRAINT "claims_key" UNIQUE (id, user_id, campaign_id),
  CONSTRAINT "claims_pkey" PRIMARY KEY (id)
);

ALTER TABLE "market"."claims"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."org_invites" (
  "id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "org_id"      uuid                     NOT NULL,
  "token_hash"  bytea                    NOT NULL,
  "expires_at"  timestamp with time zone NOT NULL,
  "accepted_by" uuid,
  "accepted_at" timestamp with time zone,
  "created_by"  uuid                     NOT NULL,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "org_invites_accept_complete" CHECK (((accepted_by IS NULL) = (accepted_at IS NULL))),
  CONSTRAINT "org_invites_expiry" CHECK ((expires_at > created_at)),
  CONSTRAINT "org_invites_pkey" PRIMARY KEY (id),
  CONSTRAINT "org_invites_token_hash_check" CHECK ((octet_length(token_hash) = 32)),
  CONSTRAINT "org_invites_token_unique" UNIQUE (token_hash)
);

ALTER TABLE "market"."org_invites"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."org_links" (
  "agency_org_id" uuid                     NOT NULL,
  "client_org_id" uuid                     NOT NULL,
  "approved_by"   uuid,
  "approved_at"   timestamp with time zone,
  "revoked_at"    timestamp with time zone,
  "created_at"    timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "org_links_approval_complete" CHECK (((approved_by IS NULL) = (approved_at IS NULL))),
  CONSTRAINT "org_links_not_self" CHECK ((agency_org_id <> client_org_id)),
  CONSTRAINT "org_links_pkey" PRIMARY KEY (agency_org_id, client_org_id)
);

ALTER TABLE "market"."org_links"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."org_members" (
  "org_id"     uuid                     NOT NULL,
  "user_id"    uuid                     NOT NULL,
  "added_by"   uuid,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "org_members_pkey" PRIMARY KEY (org_id, user_id)
);

ALTER TABLE "market"."org_members"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."organizations" (
  "id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "name"        text                     NOT NULL,
  "org_type"    text                     NOT NULL,
  "legal_name"  text,
  "npwp"        text,
  "address"     text,
  "is_agency"   boolean                  NOT NULL DEFAULT false,
  "fee_rule_id" uuid,
  "verified_by" uuid,
  "verified_at" timestamp with time zone,
  "created_by"  uuid                     NOT NULL,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "organizations_name_check" CHECK (((char_length(name) >= 2) AND (char_length(name) <= 100))),
  CONSTRAINT "organizations_npwp_check" CHECK ((npwp ~ '^[0-9]{15,16}$'::text)),
  CONSTRAINT "organizations_org_type_check" CHECK ((org_type = ANY (ARRAY['badan'::text, 'perorangan'::text]))),
  CONSTRAINT "organizations_perorangan_no_pii" CHECK (((org_type = 'badan'::text) OR ((legal_name IS NULL) AND (npwp IS NULL) AND (address IS NULL)))),
  CONSTRAINT "organizations_pkey" PRIMARY KEY (id)
);

ALTER TABLE "market"."organizations"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."profiles" (
  "id"              uuid                     NOT NULL,
  "username"        text                     NOT NULL,
  "display_name"    text                     NOT NULL,
  "avatar_path"     text,
  "trust_score"     smallint                 NOT NULL DEFAULT 50,
  "suspended_until" timestamp with time zone,
  "referral_code"   text,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "profiles_avatar_own_folder" CHECK (((avatar_path IS NULL) OR (avatar_path ~~ ((id)::text || '/%'::text)))),
  CONSTRAINT "profiles_display_name_check" CHECK (((char_length(display_name) >= 1) AND (char_length(display_name) <= 50))),
  CONSTRAINT "profiles_pkey" PRIMARY KEY (id),
  CONSTRAINT "profiles_referral_code_check" CHECK ((referral_code ~ '^[a-z0-9]{8}$'::text)),
  CONSTRAINT "profiles_referral_code_unique" UNIQUE (referral_code),
  CONSTRAINT "profiles_trust_score_check" CHECK (((trust_score >= 0) AND (trust_score <= 100))),
  CONSTRAINT "profiles_username_check" CHECK ((username ~ '^[a-z0-9_.]{3,30}$'::text)),
  CONSTRAINT "profiles_username_unique" UNIQUE (username)
);

ALTER TABLE "market"."profiles"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."rate_rules" (
  "id"             uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "campaign_id"    uuid                     NOT NULL,
  "kind"           text                     NOT NULL,
  "reward_type_id" uuid                     NOT NULL,
  "pool_id"        uuid                     NOT NULL,
  "params"         jsonb                    NOT NULL,
  "effective_from" timestamp with time zone NOT NULL DEFAULT now(),
  "effective_to"   timestamp with time zone,
  CONSTRAINT "rate_rules_effective_range" CHECK (((effective_to IS NULL) OR (effective_to > effective_from))),
  CONSTRAINT "rate_rules_kind_check" CHECK ((kind = ANY (ARRAY['per_1k_views'::text, 'flat_per_post'::text, 'milestone_bonus'::text, 'tiered_cpm'::text]))),
  CONSTRAINT "rate_rules_params_check" CHECK ((jsonb_typeof(params) = 'object'::text)),
  CONSTRAINT "rate_rules_params_per_kind"
    CHECK
    ((((kind = 'per_1k_views'::text) AND (params ? 'rate'::text)) OR ((kind = 'flat_per_post'::text) AND (params ? 'amount'::text)) OR ((kind = 'milestone_bonus'::text) AND (params
    ? 'threshold'::text) AND (params ? 'amount'::text)) OR ((kind = 'tiered_cpm'::text) AND (jsonb_typeof((params -> 'tiers'::text)) = 'array'::text)))),
  CONSTRAINT "rate_rules_pkey" PRIMARY KEY (id)
);

ALTER TABLE "market"."rate_rules"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."referrals" (
  "referred_id"  uuid                     NOT NULL,
  "referrer_id"  uuid                     NOT NULL,
  "code"         text                     NOT NULL,
  "qualified_at" timestamp with time zone,
  "bonus_until"  timestamp with time zone,
  "created_at"   timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "referrals_bonus_after_qualified" CHECK (((bonus_until IS NULL) OR (qualified_at IS NOT NULL))),
  CONSTRAINT "referrals_not_self" CHECK ((referrer_id <> referred_id)),
  CONSTRAINT "referrals_pkey" PRIMARY KEY (referred_id)
);

ALTER TABLE "market"."referrals"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."report_links" (
  "id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "campaign_id" uuid                     NOT NULL,
  "token_hash"  bytea                    NOT NULL,
  "created_by"  uuid                     NOT NULL,
  "expires_at"  timestamp with time zone,
  "revoked_at"  timestamp with time zone,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "report_links_pkey" PRIMARY KEY (id),
  CONSTRAINT "report_links_token_hash_check" CHECK ((octet_length(token_hash) = 32)),
  CONSTRAINT "report_links_token_unique" UNIQUE (token_hash)
);

ALTER TABLE "market"."report_links"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "market"."reward_types" (
  "id"                     uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "owner_org_id"           uuid,
  "code"                   text                     NOT NULL,
  "name"                   text                     NOT NULL,
  "kind"                   text                     NOT NULL,
  "unit_label"             text                     NOT NULL,
  "idr_value_per_unit"     numeric(18,2)            NOT NULL,
  "decimals"               smallint                 NOT NULL DEFAULT 0,
  "fulfillment"            text                     NOT NULL,
  "recipient_schema"       jsonb                    NOT NULL DEFAULT '[]'::jsonb,
  "stock"                  numeric(30,10),
  "webhook_url"            text,
  "webhook_secret_ref"     uuid,
  "fulfillment_margin_pct" numeric(5,2)             NOT NULL DEFAULT 0,
  "created_at"             timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "reward_types_cash_is_payout" CHECK (((kind = 'cash'::text) = (fulfillment = 'payout'::text))),
  CONSTRAINT "reward_types_code_check" CHECK ((code ~ '^[A-Z0-9_]{2,40}$'::text)),
  CONSTRAINT "reward_types_code_unique" UNIQUE NULLS NOT DISTINCT (owner_org_id, code),
  CONSTRAINT "reward_types_decimals_check" CHECK (((decimals >= 0) AND (decimals <= 6))),
  CONSTRAINT "reward_types_fulfillment_check" CHECK ((fulfillment = ANY (ARRAY['payout'::text, 'manual_export'::text, 'code_pool'::text, 'webhook'::text]))),
  CONSTRAINT "reward_types_fulfillment_margin_pct_check" CHECK (((fulfillment_margin_pct >= (0)::numeric) AND (fulfillment_margin_pct <= (100)::numeric))),
  CONSTRAINT "reward_types_idr_value_per_unit_check" CHECK ((idr_value_per_unit > (0)::numeric)),
  CONSTRAINT "reward_types_kind_check" CHECK ((kind = ANY (ARRAY['cash'::text, 'in_game'::text, 'voucher_code'::text, 'points'::text, 'physical'::text, 'custom'::text]))),
  CONSTRAINT "reward_types_pkey" PRIMARY KEY (id),
  CONSTRAINT "reward_types_recipient_schema_check" CHECK ((jsonb_typeof(recipient_schema) = 'array'::text)),
  CONSTRAINT "reward_types_stock_check" CHECK ((stock >= (0)::numeric)),
  CONSTRAINT "reward_types_webhook_complete" CHECK (((fulfillment <> 'webhook'::text) OR ((webhook_url IS NOT NULL) AND (webhook_secret_ref IS NOT NULL)))),
  CONSTRAINT "reward_types_webhook_url_check" CHECK ((webhook_url ~ '^https://'::text))
);

ALTER TABLE "market"."reward_types"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "ops"."alerts" (
  "id"          bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "kind"        text                     NOT NULL,
  "severity"    text                     NOT NULL DEFAULT 'warning'::text,
  "payload"     jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  "resolved_at" timestamp with time zone,
  "resolved_by" uuid,
  CONSTRAINT "alerts_kind_check" CHECK ((kind ~ '^[a-z_]+(\.[a-z_]+)+$'::text)),
  CONSTRAINT "alerts_payload_check" CHECK ((jsonb_typeof(payload) = 'object'::text)),
  CONSTRAINT "alerts_pkey" PRIMARY KEY (id),
  CONSTRAINT "alerts_resolution" CHECK (((resolved_at IS NULL) = (resolved_by IS NULL))),
  CONSTRAINT "alerts_severity_check" CHECK ((severity = ANY (ARRAY['info'::text, 'warning'::text, 'critical'::text])))
);

ALTER TABLE "ops"."alerts"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "ops"."audit_logs" (
  "id"       bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "actor_id" uuid,
  "action"   text                     NOT NULL,
  "target"   text                     NOT NULL,
  "before"   jsonb,
  "after"    jsonb,
  "at"       timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "audit_logs_action_check" CHECK ((action ~ '^[a-z_]+(\.[a-z_]+)+$'::text)),
  CONSTRAINT "audit_logs_pkey" PRIMARY KEY (id)
);

ALTER TABLE "ops"."audit_logs"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "ops"."broadcasts" (
  "id"              uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "title"           text                     NOT NULL,
  "body"            text                     NOT NULL,
  "segment"         jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "channels"        text[]                   NOT NULL DEFAULT '{in_app}'::text[],
  "created_by"      uuid                     NOT NULL,
  "scheduled_at"    timestamp with time zone NOT NULL DEFAULT now(),
  "sent_at"         timestamp with time zone,
  "recipient_count" integer,
  "created_at"      timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "broadcasts_body_check" CHECK (((char_length(body) >= 1) AND (char_length(body) <= 2000))),
  CONSTRAINT "broadcasts_channels_check" CHECK (((channels <@ ARRAY['in_app'::text, 'email'::text, 'push'::text]) AND (cardinality(channels) >= 1))),
  CONSTRAINT "broadcasts_pkey" PRIMARY KEY (id),
  CONSTRAINT "broadcasts_recipient_count_check" CHECK ((recipient_count >= 0)),
  CONSTRAINT "broadcasts_segment_check" CHECK ((jsonb_typeof(segment) = 'object'::text)),
  CONSTRAINT "broadcasts_sent_has_count" CHECK (((sent_at IS NULL) = (recipient_count IS NULL))),
  CONSTRAINT "broadcasts_title_check" CHECK (((char_length(title) >= 3) AND (char_length(title) <= 120)))
);

ALTER TABLE "ops"."broadcasts"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "ops"."notification_prefs" (
  "user_id"          uuid                     NOT NULL,
  "email_promotions" boolean                  NOT NULL DEFAULT true,
  "updated_at"       timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "notification_prefs_pkey" PRIMARY KEY (user_id)
);

ALTER TABLE "ops"."notification_prefs"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "ops"."notifications" (
  "id"         bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "user_id"    uuid                     NOT NULL,
  "event"      text                     NOT NULL,
  "payload"    jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "read_at"    timestamp with time zone,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "notifications_event_check" CHECK ((event ~ '^[a-z_]+(\.[a-z_]+)+$'::text)),
  CONSTRAINT "notifications_pkey" PRIMARY KEY (id)
);

ALTER TABLE "ops"."notifications"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "ops"."settings" (
  "key"        text                     NOT NULL,
  "value"      jsonb                    NOT NULL,
  "updated_by" uuid,
  "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "settings_key_check" CHECK ((key ~ '^[a-z_]+(\.[a-z_0-9]+)+$'::text)),
  CONSTRAINT "settings_pkey" PRIMARY KEY (key)
);

ALTER TABLE "ops"."settings"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "tracking"."social_accounts" (
  "id"                  uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "user_id"             uuid                     NOT NULL,
  "external_id"         text                     NOT NULL,
  "handle"              text                     NOT NULL,
  "token_ref"           uuid,
  "status"              text                     NOT NULL DEFAULT 'verified'::text,
  "followers"           integer,
  "platform_created_at" timestamp with time zone,
  "verified_at"         timestamp with time zone NOT NULL DEFAULT now(),
  "created_at"          timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "social_accounts_followers_check" CHECK ((followers >= 0)),
  CONSTRAINT "social_accounts_pkey" PRIMARY KEY (id),
  CONSTRAINT "social_accounts_status_check" CHECK ((status = ANY (ARRAY['verified'::text, 'token_expired'::text, 'revoked'::text, 'disconnected'::text])))
);

ALTER TABLE "tracking"."social_accounts"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "tracking"."submissions" (
  "id"                uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "claim_id"          uuid                     NOT NULL,
  "user_id"           uuid                     NOT NULL,
  "campaign_id"       uuid                     NOT NULL,
  "social_account_id" uuid                     NOT NULL,
  "post_id"           text                     NOT NULL,
  "url"               text                     NOT NULL,
  "posted_at"         timestamp with time zone NOT NULL,
  "counted_views"     bigint                   NOT NULL DEFAULT 0,
  "last_snapshot_at"  timestamp with time zone,
  "next_poll_at"      timestamp with time zone,
  "locked_at"         timestamp with time zone,
  "created_at"        timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "submissions_counted_views_check" CHECK ((counted_views >= 0)),
  CONSTRAINT "submissions_one_per_claim" UNIQUE (claim_id),
  CONSTRAINT "submissions_pkey" PRIMARY KEY (id),
  CONSTRAINT "submissions_url_check" CHECK ((url ~ '^https://'::text))
);

ALTER TABLE "tracking"."submissions"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "tracking"."view_snapshots" (
  "id"            bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "submission_id" uuid                     NOT NULL,
  "taken_at"      timestamp with time zone NOT NULL DEFAULT now(),
  "views"         bigint                   NOT NULL,
  "likes"         bigint,
  "comments"      bigint,
  "shares"        bigint,
  "is_final"      boolean                  NOT NULL DEFAULT false,
  "raw"           jsonb,
  CONSTRAINT "view_snapshots_comments_check" CHECK ((comments >= 0)),
  CONSTRAINT "view_snapshots_likes_check" CHECK ((likes >= 0)),
  CONSTRAINT "view_snapshots_pkey" PRIMARY KEY (id),
  CONSTRAINT "view_snapshots_shares_check" CHECK ((shares >= 0)),
  CONSTRAINT "view_snapshots_unique" UNIQUE (submission_id, taken_at),
  CONSTRAINT "view_snapshots_views_check" CHECK ((views >= 0))
);

ALTER TABLE "tracking"."view_snapshots"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "trust"."fraud_flags" (
  "id"          uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "target_type" text                     NOT NULL,
  "target_id"   uuid                     NOT NULL,
  "signal"      text                     NOT NULL,
  "score"       numeric(5,2),
  "status"      text                     NOT NULL DEFAULT 'open'::text,
  "details"     jsonb                    NOT NULL DEFAULT '{}'::jsonb,
  "resolved_by" uuid,
  "resolved_at" timestamp with time zone,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "fraud_flags_pkey" PRIMARY KEY (id),
  CONSTRAINT "fraud_flags_resolution" CHECK (((status = ANY (ARRAY['open'::text, 'held'::text])) = (resolved_at IS NULL))),
  CONSTRAINT "fraud_flags_score_check" CHECK (((score >= (0)::numeric) AND (score <= (100)::numeric))),
  CONSTRAINT "fraud_flags_signal_check" CHECK ((signal ~ '^FR-[0-9]{2}$'::text)),
  CONSTRAINT "fraud_flags_status_check" CHECK ((status = ANY (ARRAY['open'::text, 'held'::text, 'dismissed'::text, 'actioned'::text]))),
  CONSTRAINT "fraud_flags_target_type_check" CHECK ((target_type = ANY (ARRAY['submission'::text, 'profile'::text, 'social_account'::text, 'payout'::text])))
);

ALTER TABLE "trust"."fraud_flags"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "trust"."review_decisions" (
  "id"          bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "target_type" text                     NOT NULL,
  "target_id"   uuid                     NOT NULL,
  "actor_id"    uuid,
  "decision"    text                     NOT NULL,
  "reason_code" text,
  "message"     text,
  "note"        text,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "review_appeal_on_submission" CHECK (((decision <> 'appeal'::text) OR (target_type = 'submission'::text))),
  CONSTRAINT "review_decisions_decision_check"
    CHECK ((decision = ANY (ARRAY['approve'::text, 'reject'::text, 'auto_approve'::text, 'appeal'::text, 'uphold'::text, 'overturn'::text]))),
  CONSTRAINT "review_decisions_pkey" PRIMARY KEY (id),
  CONSTRAINT "review_decisions_target_type_check" CHECK ((target_type = ANY (ARRAY['campaign'::text, 'submission'::text, 'kyc'::text, 'org'::text]))),
  CONSTRAINT "review_reject_has_reason" CHECK (((decision <> 'reject'::text) OR (reason_code IS NOT NULL)))
);

ALTER TABLE "trust"."review_decisions"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "trust"."score_events" (
  "id"         bigint                   GENERATED ALWAYS AS IDENTITY NOT NULL,
  "user_id"    uuid                     NOT NULL,
  "delta"      smallint                 NOT NULL,
  "reason"     text                     NOT NULL,
  "ref_id"     text,
  "created_by" uuid,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "score_events_delta_check" CHECK (((delta <> 0) AND ((delta >= '-100'::integer) AND (delta <= 100)))),
  CONSTRAINT "score_events_override_has_actor" CHECK (((reason <> 'admin_override'::text) OR (created_by IS NOT NULL))),
  CONSTRAINT "score_events_pkey" PRIMARY KEY (id),
  CONSTRAINT "score_events_reason_check"
    CHECK
    ((reason = ANY (ARRAY['submission_approved'::text, 'clean_tenure'::text, 'submission_rejected'::text, 'fraud_flag'::text, 'appeal_failed'::text, 'admin_override'::text])))
);

ALTER TABLE "trust"."score_events"
  ENABLE ROW LEVEL SECURITY;

CREATE TYPE "finance"."earning_state" AS ENUM (
  'pending',
  'available',
  'withdrawn'
);

ALTER TABLE "finance"."ledger_entries"
  ADD COLUMN "state" finance.earning_state;

CREATE TYPE "finance"."fulfillment_status" AS ENUM (
  'requested',
  'on_hold',
  'processing',
  'cancelled',
  'delivered',
  'failed',
  'returned'
);

ALTER TABLE "finance"."fulfillments"
  ADD COLUMN "status" finance.fulfillment_status NOT NULL DEFAULT 'requested'::finance.fulfillment_status;

CREATE TYPE "finance"."payout_status" AS ENUM (
  'requested',
  'on_hold',
  'processing',
  'cancelled',
  'paid',
  'failed',
  'returned'
);

ALTER TABLE "finance"."payouts"
  ADD COLUMN "status" finance.payout_status NOT NULL DEFAULT 'requested'::finance.payout_status;

CREATE TYPE "market"."campaign_status" AS ENUM (
  'draft',
  'in_review',
  'cancelled',
  'scheduled',
  'rejected',
  'live',
  'paused',
  'tracking',
  'exhausted',
  'settling',
  'settled'
);

ALTER TABLE "market"."campaigns"
  ADD COLUMN "status" market.campaign_status NOT NULL DEFAULT 'draft'::market.campaign_status;

CREATE TYPE "market"."claim_status" AS ENUM (
  'open',
  'submitted',
  'expired',
  'released'
);

ALTER TABLE "market"."claims"
  ADD COLUMN "status" market.claim_status NOT NULL DEFAULT 'open'::market.claim_status;

CREATE TYPE "market"."org_role" AS ENUM (
  'brand_owner',
  'brand_manager',
  'brand_finance',
  'brand_viewer'
);

ALTER TABLE "market"."org_invites"
  ADD COLUMN "role" market.org_role NOT NULL;

ALTER TABLE "market"."org_members"
  ADD COLUMN "role" market.org_role NOT NULL;

CREATE TYPE "market"."org_status" AS ENUM (
  'pending_verification',
  'verified',
  'suspended'
);

ALTER TABLE "market"."organizations"
  ADD COLUMN "status" market.org_status NOT NULL DEFAULT 'pending_verification'::market.org_status;

CREATE TYPE "market"."platform" AS ENUM (
  'tiktok',
  'instagram',
  'youtube',
  'threads',
  'facebook',
  'x'
);

ALTER TABLE "market"."campaigns"
  ADD COLUMN "platforms" market.platform[] NOT NULL;

ALTER TABLE "market"."rate_rules"
  ADD COLUMN "platform" market.platform;

ALTER TABLE "tracking"."social_accounts"
  ADD COLUMN "platform" market.platform NOT NULL;

ALTER TABLE "tracking"."submissions"
  ADD COLUMN "platform" market.platform NOT NULL;

CREATE TYPE "market"."profile_status" AS ENUM (
  'active',
  'suspended',
  'banned',
  'closed'
);

ALTER TABLE "market"."profiles"
  ADD COLUMN "status" market.profile_status NOT NULL DEFAULT 'active'::market.profile_status;

CREATE TYPE "tracking"."submission_status" AS ENUM (
  'validating',
  'in_review',
  'tracking',
  'rejected',
  'flagged',
  'forfeited',
  'locked',
  'appealed',
  'settled',
  'rejected_final'
);

ALTER TABLE "tracking"."submissions"
  ADD COLUMN "status" tracking.submission_status NOT NULL DEFAULT 'validating'::tracking.submission_status;

CREATE OR REPLACE FUNCTION api.accept_org_invite (
  p_token text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  inv market.org_invites;
begin
  select * into inv from market.org_invites where token_hash = sha256(convert_to(coalesce(p_token, ''), 'UTF8')) for update;
  if inv.id is null then
    perform market.fail('not_found:invite', 'link undangan tidak dikenal', 'P0002');
  end if;
  if exists (select 1 from market.org_members m where m.org_id = inv.org_id and m.user_id = uid) then
    return inv.org_id;
  end if;
  if inv.accepted_at is not null then
    perform market.fail('invite_used', 'link undangan sudah dipakai');
  end if;
  if inv.expires_at <= now() then
    perform market.fail('invite_expired', 'link undangan kedaluwarsa; minta link baru');
  end if;
  if exists (select 1 from market.profiles p where p.id = uid and p.status <> 'active') then
    perform market.fail('not_eligible:profile_inactive', 'akun tidak aktif');
  end if;
  perform market.ensure_member_profile(uid);
  insert into market.org_members (org_id, user_id, role, added_by) values (inv.org_id, uid, inv.role, inv.created_by);
  update market.org_invites set accepted_by = uid, accepted_at = now() where id = inv.id;
  return inv.org_id;
end $function$;

CREATE OR REPLACE FUNCTION api.admin_overview()
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  month_start timestamptz := date_trunc('month', now() at time zone 'Asia/Jakarta') at time zone 'Asia/Jakarta';
  rev uuid := (select a.id from finance.ledger_accounts a join market.reward_types rt on rt.id = a.reward_type_id
               where a.owner_type = 'platform_revenue' and rt.code = 'IDR' and rt.owner_org_id is null);
begin
  if not ops.has_admin() then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'gmv', (select jsonb_build_object('month', coalesce(sum(i.total) filter (where i.paid_at >= month_start), 0),
                                      'all_time', coalesce(sum(i.total), 0))
              from finance.invoices i where i.status = 'paid'),
    'revenue', (select jsonb_build_object('month', coalesce(sum(e.amount) filter (where e.created_at >= month_start), 0),
                                          'all_time', coalesce(sum(e.amount), 0))
                  from finance.ledger_entries e where e.account_id = rev),
    'active_campaigns', (select count(*) from market.campaigns c where c.status in ('live', 'paused', 'tracking')),
    'payout_pending', (select jsonb_build_object('count', count(*), 'sum', coalesce(sum(p.amount), 0))
                         from finance.payouts p where p.status in ('requested', 'on_hold', 'processing')),
    'fraud_queue', (select count(*) from trust.fraud_flags f where f.status in ('open', 'held')),
    'tracking', jsonb_build_object(
      'overdue', (select count(*) from tracking.submissions s
                   where s.status in ('tracking', 'flagged') and s.next_poll_at < now() - interval '2 hours'),
      'last_snapshot_age_seconds', (select floor(extract(epoch from now() - max(v.taken_at))) from tracking.view_snapshots v)),
    'open_alerts', (select count(*) from ops.alerts a where a.resolved_at is null));
end $function$;

CREATE OR REPLACE FUNCTION api.appeal_submission (
  p_submission uuid,
  p_message    text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  s tracking.submissions;
  pr market.profiles;
begin
  select * into s from tracking.submissions where id = p_submission for update;
  if s.id is null or s.user_id <> uid then
    perform market.fail('not_found:submission', null, 'P0002');
  end if;
  select * into pr from market.profiles where id = uid;
  if pr.status is distinct from 'active' then
    perform market.fail('not_eligible:profile_inactive', 'akun tidak aktif');
  end if;
  if char_length(btrim(coalesce(p_message, ''))) not between 1 and 1000 then
    perform market.fail('invalid:message', 'alasan banding 1–1000 karakter');
  end if;
  if s.status <> 'rejected' then
    perform market.fail('invalid_state:' || s.status, 'banding hanya untuk submisi yang ditolak');
  end if;
  begin
    insert into trust.review_decisions (target_type, target_id, actor_id, decision, message)
    values ('submission', s.id, uid, 'appeal', btrim(p_message));
  exception when unique_violation then
    perform market.fail('appeal_used', 'banding hanya sekali per submisi');
  end;
  update tracking.submissions set status = 'appealed' where id = s.id;
end $function$;

CREATE OR REPLACE FUNCTION api.approve_payout_batch (
  p_batch uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  update finance.payout_batches set approved_by = (select auth.uid()), status = 'approved'
   where id = p_batch and status = 'draft';
  if not found then
    raise exception 'batch_not_draft' using errcode = 'P0001';
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.approve_refund (
  p_refund uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  update finance.org_refunds set status = 'approved', approved_by = (select auth.uid()) where id = p_refund and status = 'requested';
  if not found then
    raise exception 'invalid_state:refund' using errcode = 'P0001';
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_attach_export (
  p_batch    uuid,
  p_file_ref text,
  p_held     jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  b finance.payout_batches;
  x record;
begin
  select * into b from finance.payout_batches pb where pb.id = p_batch for update;
  if not found then
    raise exception 'not_found:batch' using errcode = 'P0002';
  end if;
  if b.status = 'exported' and b.file_ref = p_file_ref then
    return;
  end if;
  if b.status <> 'approved' then
    raise exception 'invalid_state:%', b.status using errcode = 'P0001';
  end if;
  if p_file_ref is null or btrim(p_file_ref) = '' then
    raise exception 'invalid:file_ref' using errcode = 'P0001';
  end if;
  for x in select * from jsonb_to_recordset(coalesce(p_held, '[]')) h(payout_id uuid, reason text) loop
    update finance.payouts set status = 'on_hold', hold_reason = coalesce(nullif(btrim(x.reason), ''), 'export_check_failed')
     where id = x.payout_id and batch_id = b.id and status = 'requested';
    if found then
      perform ops.raise_alert('payout.on_hold', 'warning', jsonb_build_object('payout_id', x.payout_id, 'batch_id', b.id,
                                                                                'reason', x.reason));
    end if;
  end loop;
  update finance.payouts set status = 'processing' where batch_id = b.id and status = 'requested';
  update finance.payout_batches pb set status = 'exported', file_ref = p_file_ref,
         count = (select count(*) from finance.payouts p where p.batch_id = b.id and p.status = 'processing'),
         total = coalesce((select sum(p.amount - p.fee) from finance.payouts p where p.batch_id = b.id and p.status = 'processing'), 0)
   where pb.id = b.id;
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_attach_proof (
  p_target    text,
  p_id        uuid,
  p_proof_ref text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  st text;
begin
  if p_proof_ref is null or btrim(p_proof_ref) = '' then
    raise exception 'invalid:proof_ref' using errcode = 'P0001';
  end if;
  if p_target = 'batch' then
    select b.status into st from finance.payout_batches b where b.id = p_id for update;
    if st is null then
      raise exception 'not_found:batch' using errcode = 'P0002';
    end if;
    if st not in ('paid', 'closed') then
      raise exception 'invalid_state:%', st using errcode = 'P0001';
    end if;
    update finance.payouts set proof_ref = p_proof_ref where batch_id = p_id and status = 'paid';
    update finance.payout_batches set status = 'closed' where id = p_id;
  elsif p_target = 'refund' then
    perform finance.pay_refund(p_id, p_proof_ref);
  else
    raise exception 'invalid:target' using errcode = 'P0001';
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_close_account (
  p_user uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pr market.profiles;
begin
  select * into pr from market.profiles p where p.id = p_user for update;
  if not found then
    return jsonb_build_object('ok', true, 'reason', 'no_profile');
  end if;
  if pr.status = 'closed' then
    return jsonb_build_object('ok', true, 'reason', 'already_closed');
  end if;
  if exists (select 1 from finance.ledger_accounts a join finance.ledger_entries e on e.account_id = a.id
             where a.owner_type = 'user_wallet' and a.owner_id = p_user and e.state in ('pending', 'available')
             group by a.id, e.state having sum(e.amount) <> 0) then
    return jsonb_build_object('ok', false, 'reason', 'balance_remaining');
  end if;
  if exists (select 1 from finance.payouts p where p.user_id = p_user and p.status in ('requested', 'on_hold', 'processing', 'failed')) then
    return jsonb_build_object('ok', false, 'reason', 'payout_in_progress');
  end if;
  if exists (select 1 from finance.fulfillments f where f.user_id = p_user and f.status in ('requested', 'on_hold', 'processing', 'failed')) then
    return jsonb_build_object('ok', false, 'reason', 'fulfillment_in_progress');
  end if;

  update tracking.submissions set status = 'forfeited', next_poll_at = null where user_id = p_user and status in ('tracking', 'flagged');
  update tracking.submissions set status = 'rejected' where user_id = p_user and status in ('validating', 'in_review');
  update tracking.submissions set status = 'rejected_final' where user_id = p_user and status = 'appealed';
  update market.claims set status = 'released' where user_id = p_user and status = 'open';
  delete from vault.secrets v where v.id in (select a.token_ref from tracking.social_accounts a where a.user_id = p_user);
  delete from tracking.social_accounts a
   where a.user_id = p_user and not exists (select 1 from tracking.submissions s where s.social_account_id = a.id);
  update tracking.social_accounts set status = 'disconnected', token_ref = null, handle = 'deleted', followers = null
   where user_id = p_user;
  update market.profiles set username = 'deleted_' || substr(md5(id::text), 1, 12), display_name = 'Akun dihapus',
         avatar_path = null, referral_code = null, suspended_until = null, status = 'closed'
   where id = p_user;
  return jsonb_build_object('ok', true, 'reason', null);
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_collect_ids()
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return jsonb_build_object(
    'user_ids', coalesce((select jsonb_agg(p.id order by p.id) from market.profiles p where p.status <> 'closed'), '[]'),
    'method_ids', coalesce((select jsonb_agg(distinct x.method_id) from finance.payouts x
                            join market.profiles p on p.id = x.user_id where p.status <> 'closed'), '[]'),
    'recipient_refs', coalesce((select jsonb_agg(distinct f.recipient_ref) from finance.fulfillments f
                                join market.profiles p on p.id = f.user_id
                                where f.recipient_ref is not null and p.status <> 'closed'), '[]'));
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_fulfillment_export (
  p_reward_type uuid
)
  RETURNS TABLE (
    id            uuid,
    user_id       uuid,
    amount        numeric,
    recipient     jsonb,
    recipient_ref uuid
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return query
  select f.id, f.user_id, f.amount::numeric, f.recipient, f.recipient_ref
    from finance.fulfillments f join market.reward_types rt on rt.id = f.reward_type_id
   where f.reward_type_id = p_reward_type and f.status = 'requested' and rt.fulfillment = 'manual_export'
   order by f.created_at, f.id;
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_get_batch (
  p_batch uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  b finance.payout_batches;
begin
  select * into b from finance.payout_batches x where x.id = p_batch;
  if not found then
    raise exception 'not_found:batch' using errcode = 'P0002';
  end if;
  if b.status <> 'approved' then
    raise exception 'invalid_state:%', b.status using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'batch', jsonb_build_object('id', b.id, 'status', b.status, 'created_by', b.created_by, 'approved_by', b.approved_by),
    'payouts', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'user_id', p.user_id, 'method_id', p.method_id,
                                                             'amount', p.amount, 'fee', p.fee) order by p.id)
                         from finance.payouts p where p.batch_id = b.id and p.status = 'requested'), '[]'));
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_get_payout (
  p_payout uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  p finance.payouts;
begin
  select * into p from finance.payouts x where x.id = p_payout;
  if not found then
    raise exception 'not_found:payout' using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', p.id, 'user_id', p.user_id, 'method_id', p.method_id, 'amount', p.amount, 'fee', p.fee,
                            'net_amount', p.amount - p.fee, 'channel', p.channel, 'status', p.status);
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_mark_instant (
  p_payout       uuid,
  p_status       text,
  p_provider_ref text,
  p_error        text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  p finance.payouts;
begin
  if p_status is null or p_status not in ('processing', 'paid', 'failed') then
    raise exception 'invalid:status' using errcode = 'P0001';
  end if;
  select * into p from finance.payouts x where x.id = p_payout for update;
  if not found then
    raise exception 'not_found:payout' using errcode = 'P0002';
  end if;
  if p.channel <> 'instant' then
    raise exception 'invalid:channel' using errcode = 'P0001';
  end if;
  if p.status::text = p_status or (p_status = 'failed' and p.status = 'returned') or (p_status = 'processing' and p.status <> 'requested') then
    return;
  end if;
  begin
    if p.status = 'requested' then
      update finance.payouts set status = 'processing', provider_ref = coalesce(p_provider_ref, provider_ref) where id = p.id;
    elsif p_provider_ref is not null then
      update finance.payouts set provider_ref = p_provider_ref where id = p.id and provider_ref is null;
    end if;
  exception when unique_violation then
    raise exception 'duplicate_provider_ref' using errcode = '23505';
  end;
  if p_status = 'paid' then
    update finance.payouts set status = 'paid', paid_at = now() where id = p.id;
    perform ops.enqueue_notification(p.user_id, 'payout.paid', finance.amount_ref(finance.idr(), p.amount - p.fee)
                                     || jsonb_build_object('payout_id', p.id, 'channel', p.channel));
  elsif p_status = 'failed' then
    perform finance.return_payout(p.id, p_error);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_pph21 (
  p_from date,
  p_to   date
)
  RETURNS TABLE (
    user_id uuid,
    gross   numeric
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return query
  select p.user_id, sum(p.amount)::numeric from finance.payouts p
   where p.status = 'paid' and p.paid_at >= (p_from::timestamp at time zone 'Asia/Jakarta')
     and p.paid_at < ((p_to + 1)::timestamp at time zone 'Asia/Jakarta')
   group by p.user_id order by p.user_id;
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_raise_fraud_flag (
  p_target_type text,
  p_target_id   uuid,
  p_signal      text,
  p_score       numeric,
  p_details     jsonb
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return trust.raise_flag(p_target_type, p_target_id, p_signal, p_score, p_details);
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_report_orphans (
  p_missing jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if exists (select 1 from jsonb_each(coalesce(p_missing, '{}')) e
             where jsonb_typeof(e.value) = 'array' and jsonb_array_length(e.value) > 0) then
    perform ops.raise_alert('reconcile.orphans', 'critical', p_missing);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.buy_pin (
  p_campaign uuid,
  p_days     integer
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  price numeric := coalesce((select (s.value #>> '{}')::numeric from ops.settings s where s.key = 'public.billing.pin_price_per_week_idr'),
                            500000);
  inv finance.invoices;
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager', 'brand_finance') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager/brand_finance org', '42501');
  end if;
  if c.status not in ('scheduled', 'live', 'paused') then
    perform market.fail('invalid_state:' || c.status, 'pin hanya untuk campaign terjadwal/berjalan');
  end if;
  if p_days is null or p_days not between 1 and 90 then
    perform market.fail('invalid:days', 'durasi pin 1–90 hari');
  end if;
  inv := finance.issue_invoice(c.org_id, c.id, 'pinned', 0, ceil(p_days / 7.0) * price,
                               greatest(now(), coalesce(c.pinned_until, now())) + make_interval(days => p_days));
  return inv.id;
end $function$;

CREATE OR REPLACE FUNCTION api.campaign_detail (
  p_campaign uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  staff boolean;
  chk record;
  bud jsonb;
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null or not market.campaign_visible(c) then
    perform market.fail('not_found:campaign', 'campaign tidak ada atau tidak terlihat', 'P0002');
  end if;
  staff := ops.is_org_member(c.org_id) or ops.has_admin();
  select * into chk from market.claim_check(c.id);
  bud := market.campaign_budget(c.id);
  return jsonb_build_object(
    'campaign', (select to_jsonb(v) from (select c.id, c.org_id, c.slug, c.title, c.type, c.category_id, c.status, c.platforms,
                   c.brief, c.required_hashtags, c.required_mentions, c.required_links, c.sponsored_label, c.min_duration_sec,
                   c.max_duration_sec, c.dos, c.donts, c.example_urls, c.faq, c.service_mode, c.start_at, c.submit_deadline,
                   c.view_window_days, c.review_mode, c.min_followers, c.min_account_age_days, c.min_trust_score, c.kyc_required,
                   c.min_views, c.max_clips_per_clipper, c.clipper_quota, c.allow_video_reuse, c.visibility, c.is_template,
                   c.pinned_until, c.pinned_rank, c.created_at) v),
    'rules', bud -> 'rates',
    'pools', bud -> 'pools',
    'budget_idr', bud -> 'budget_idr',
    'remaining_idr', bud -> 'remaining_idr',
    'est_remaining_views', bud -> 'est_remaining_views',
    'assets', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', a.id, 'kind', a.kind, 'audience', a.audience, 'url', a.url, 'size_bytes', a.size_bytes,
                  'storage_path', a.storage_path,
                  'bucket', case when a.storage_path is null then null when a.kind = 'cover' then 'campaign-covers' else 'campaign-assets' end)
                  order by a.kind = 'cover' desc, a.created_at, a.id)
                from market.campaign_assets a where a.campaign_id = c.id and (a.audience = 'clipper' or staff)), '[]'::jsonb),
    'my', jsonb_build_object(
      'claim', (select jsonb_build_object('id', cl.id, 'status', cl.status, 'expires_at', cl.expires_at, 'created_at', cl.created_at)
                  from market.claims cl where cl.campaign_id = c.id and cl.user_id = uid
                 order by cl.created_at desc, cl.id limit 1),
      'submissions', coalesce((select jsonb_agg(jsonb_build_object(
                         'id', s.id, 'status', s.status, 'platform', s.platform, 'url', s.url, 'counted_views', s.counted_views,
                         'last_snapshot_at', s.last_snapshot_at, 'created_at', s.created_at,
                         'review', (select jsonb_build_object('decision', d.decision, 'reason_code', d.reason_code, 'message', d.message,
                                                              'at', d.created_at)
                                      from trust.review_decisions d
                                     where d.target_type = 'submission' and d.target_id = s.id and d.decision <> 'appeal'
                                     order by d.created_at desc, d.id desc limit 1),
                         'appeal_used', exists (select 1 from trust.review_decisions d where d.target_type = 'submission'
                                                and d.target_id = s.id and d.decision = 'appeal'))
                         order by s.created_at desc)
                       from tracking.submissions s where s.campaign_id = c.id and s.user_id = uid), '[]'::jsonb),
      'clips_used', (select count(*) from tracking.submissions s where s.campaign_id = c.id and s.user_id = uid
                     and s.status not in ('rejected', 'rejected_final'))),
    'cta_state', chk.state,
    'cta_reason', chk.reason);
end $function$;

CREATE OR REPLACE FUNCTION api.campaign_stats (
  p_campaign uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  rep jsonb;
  bud jsonb;
  proj jsonb;
  views numeric;
  counted constant tracking.submission_status[] := array['tracking', 'flagged', 'locked', 'settled']::tracking.submission_status[];
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not (ops.is_org_member(c.org_id) or ops.has_admin()) then
    perform market.fail('auth:forbidden', 'dashboard hanya untuk anggota org', '42501');
  end if;
  rep := market.campaign_report(c.id);
  bud := market.campaign_budget(c.id);
  proj := market.campaign_projection(c.id);
  views := (rep ->> 'views_valid')::numeric;
  return rep || jsonb_build_object(
    'pools', bud -> 'pools',
    'est_remaining_views', bud -> 'est_remaining_views',
    'budget_idr', proj -> 'budget_idr',
    'spent_idr', proj -> 'spent_idr',
    'remaining_idr', proj -> 'remaining_idr',
    'utilization_pct', proj -> 'utilization_pct',
    'ecpm_idr', case when views > 0 then trim_scale(round((proj ->> 'spent_idr')::numeric / views * 1000, 2)) end,
    'projection', proj,
    'daily', coalesce((select jsonb_agg(jsonb_build_object('day', d.day, 'views', d.views) order by d.day)
                         from (select (x.taken_at at time zone 'Asia/Jakarta')::date as day, sum(x.delta) as views
                                 from (select vs.taken_at,
                                              vs.views - coalesce(lag(vs.views) over (partition by vs.submission_id order by vs.taken_at), 0) as delta
                                         from tracking.view_snapshots vs join tracking.submissions s on s.id = vs.submission_id
                                        where s.campaign_id = c.id and s.status = any (counted)) x
                                group by 1) d), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION api.cancel_fulfillment (
  p_fulfillment uuid,
  p_reason      text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  f finance.fulfillments;
  wallet uuid;
begin
  if not ops.has_admin('admin_ops', 'admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'invalid:reason' using errcode = 'P0001';
  end if;
  select * into f from finance.fulfillments x where x.id = p_fulfillment for update;
  if not found then
    raise exception 'not_found:fulfillment' using errcode = 'P0002';
  end if;
  if f.status in ('cancelled', 'returned') then
    return;
  end if;
  if f.status = 'delivered' then
    raise exception 'invalid_state:delivered' using errcode = 'P0001';
  end if;
  if exists (select 1 from finance.reward_codes rc where rc.fulfillment_id = f.id) then
    raise exception 'code_assigned' using errcode = 'P0001';
  end if;
  if f.status = 'requested' then
    update finance.fulfillments set status = 'on_hold' where id = f.id;
  elsif f.status = 'processing' then
    update finance.fulfillments set status = 'failed' where id = f.id;
  end if;
  update finance.fulfillments set status = case when f.status in ('requested', 'on_hold') then 'cancelled' else 'returned' end
                                           ::finance.fulfillment_status,
         last_error = p_reason, next_retry_at = null
   where id = f.id;
  wallet := finance.account('user_wallet', f.user_id, f.reward_type_id);
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(wallet, -f.amount, 'fulfillment', f.id || ':return', 'withdrawn'),
    finance.e(wallet, f.amount, 'fulfillment', f.id || ':return', 'available')));
  perform ops.enqueue_notification(f.user_id, 'fulfillment.cancelled', finance.amount_ref(f.reward_type_id, f.amount)
                                   || jsonb_build_object('fulfillment_id', f.id, 'reason', p_reason));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'fulfillment.cancel', 'fulfillment:' || f.id, jsonb_build_object('status', f.status),
          jsonb_build_object('reason', p_reason));
end $function$;

CREATE OR REPLACE FUNCTION api.cancel_payout (
  p_payout uuid,
  p_reason text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  po finance.payouts;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'invalid:reason' using errcode = 'P0001';
  end if;
  select * into po from finance.payouts p where p.id = p_payout for update;
  if not found then
    raise exception 'not_found:payout' using errcode = 'P0002';
  end if;
  if po.status = 'cancelled' then
    return;
  end if;
  if not (po.status = 'on_hold' or (po.status = 'requested' and po.channel = 'batch')) then
    raise exception 'invalid_state:%', po.status using errcode = 'P0001';
  end if;
  if po.status = 'requested' then
    update finance.payouts set status = 'on_hold', hold_reason = p_reason where id = po.id;
  end if;
  update finance.payouts set status = 'cancelled', hold_reason = p_reason where id = po.id;
  perform finance.unwind_payout_journal(po);
  perform ops.enqueue_notification(po.user_id, 'payout.cancelled', finance.amount_ref(finance.idr(), po.amount)
                                   || jsonb_build_object('payout_id', po.id, 'channel', po.channel, 'reason', p_reason));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout.cancel', 'payout:' || po.id, jsonb_build_object('status', po.status),
          jsonb_build_object('status', 'cancelled', 'reason', p_reason));
end $function$;

CREATE OR REPLACE FUNCTION api.claim_campaign (
  p_campaign uuid
)
  RETURNS market.claims
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  chk record;
  cl market.claims;
  hours int := coalesce((select (s.value #>> '{}')::int from ops.settings s where s.key = 'public.market.claim_hours'), 48);
begin
  perform pg_advisory_xact_lock(hashtextextended('claim:' || p_campaign::text, 0));
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null or not market.campaign_visible(c) then
    perform market.fail('not_found:campaign', 'campaign tidak ada atau tidak terlihat', 'P0002');
  end if;
  update market.claims set status = 'expired'
   where campaign_id = c.id and user_id = uid and status = 'open' and expires_at <= now();
  select * into chk from market.claim_check(c.id);
  if chk.state is distinct from 'can_claim' then
    perform market.fail(case chk.state when 'claimed_not_submitted' then 'already_claimed'
                                       when 'not_eligible' then 'not_eligible:' || chk.reason
                                       else chk.state end,
                        'claim ditolak');
  end if;
  begin
    insert into market.claims (campaign_id, user_id, expires_at)
    values (c.id, uid, now() + make_interval(hours => hours))
    returning * into cl;
  exception when unique_violation then
    perform market.fail('already_claimed', 'masih ada claim terbuka di campaign ini');
  end;
  return cl;
end $function$;

CREATE OR REPLACE FUNCTION api.confirm_invoice_payment (
  p_invoice uuid,
  p_amount  numeric,
  p_paid_at timestamp with time zone,
  p_ref     text,
  p_channel text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  inv finance.invoices;
  idr uuid := finance.idr();
  bank uuid;
  entries jsonb := '[]';
  pool_idr numeric := 0;
  revenue numeric;
  x record;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into inv from finance.invoices i where i.id = p_invoice for update;
  if not found then
    raise exception 'not_found:invoice' using errcode = 'P0002';
  end if;
  if inv.status = 'paid' and inv.payment_ref = p_ref then
    return;  -- replay konfirmasi yang sama
  end if;
  if inv.status <> 'issued' then
    raise exception 'invalid_state:%', inv.status using errcode = 'P0001';
  end if;
  if p_amount is distinct from inv.total then
    raise exception 'amount_mismatch' using errcode = 'P0001', detail = format('invoice %s, dibayar %s', inv.total, p_amount);
  end if;
  if p_ref is null or btrim(p_ref) = '' or p_channel is null or p_channel not in ('qris', 'transfer') then
    raise exception 'invalid:payment' using errcode = 'P0001';
  end if;
  if exists (select 1 from finance.invoices i where i.payment_ref = btrim(p_ref)) then
    raise exception 'duplicate_payment_ref' using errcode = '23505';
  end if;
  if inv.kind = 'campaign' and exists (select 1 from finance.invoices i where i.campaign_id = inv.campaign_id and i.kind = 'campaign'
                                                                        and i.status = 'paid') then
    raise exception 'campaign_already_funded' using errcode = 'P0001';
  end if;

  update finance.invoices set status = 'paid', payment_channel = p_channel, payment_ref = btrim(p_ref), paid_amount = p_amount,
         paid_at = coalesce(p_paid_at, now()), confirmed_by = (select auth.uid())
   where id = inv.id;

  bank := finance.account('bank_clearing', null, idr);
  entries := jsonb_build_array(finance.e(bank, -inv.total, 'invoice_payment', inv.id::text),
                               finance.e(finance.account('tax_payable', null, idr), inv.tax, 'invoice_payment', inv.id::text));
  revenue := inv.mgmt_fee + inv.admin_fee + inv.service_fee;

  if inv.kind in ('campaign', 'topup') then
    for x in
      select rp.id, rp.reward_type_id, rp.campaign_id, coalesce(t.amount, rp.total) as amount
        from finance.reward_pools rp
        left join (select (e ->> 'pool_id')::uuid as pool_id, sum((e ->> 'amount')::numeric) as amount
                     from jsonb_array_elements(coalesce(inv.pool_topups, '[]')) e group by 1) t on t.pool_id = rp.id
       where rp.campaign_id = inv.campaign_id and (inv.kind = 'campaign' or t.pool_id is not null)
       order by rp.id
      for update of rp
    loop
      if x.amount is null or x.amount <= 0 then
        raise exception 'invalid:pool_topups' using errcode = 'P0001';
      end if;
      if inv.kind = 'topup' then
        update finance.reward_pools set total = total + x.amount where id = x.id;
      end if;
      entries := entries || jsonb_build_array(finance.e(finance.account('campaign_pool', x.id, x.reward_type_id), x.amount,
                                                        'invoice_payment', inv.id::text));
      if x.reward_type_id = idr then
        pool_idr := pool_idr + x.amount;
      else
        entries := entries || jsonb_build_array(finance.e(finance.account('bank_clearing', null, x.reward_type_id), -x.amount,
                                                          'invoice_payment', inv.id::text));
      end if;
    end loop;
    if inv.kind = 'topup' and (select count(distinct e ->> 'pool_id') from jsonb_array_elements(inv.pool_topups) e)
         <> (select count(*) from finance.reward_pools rp join jsonb_array_elements(inv.pool_topups) e on (e ->> 'pool_id')::uuid = rp.id
             where rp.campaign_id = inv.campaign_id) then
      raise exception 'invalid:pool_topups' using errcode = 'P0001';  -- pool milik campaign lain / tidak ada
    end if;
    if pool_idr <> inv.subtotal then
      raise exception 'invoice_pool_mismatch' using errcode = 'P0001',
        detail = format('pool Rupiah %s ≠ subtotal %s', pool_idr, inv.subtotal);
    end if;
  else
    revenue := revenue + inv.subtotal;
  end if;
  entries := entries || jsonb_build_array(finance.e(finance.account('platform_revenue', null, idr), revenue,
                                                    'invoice_payment', inv.id::text));
  perform finance.post(gen_random_uuid(), entries);

  if inv.kind = 'pinned' then
    update market.campaigns set pinned_until = greatest(coalesce(pinned_until, inv.pin_until), inv.pin_until)
     where id = inv.campaign_id;
  end if;
  perform market.notify_org(inv.org_id, array['brand_owner', 'brand_finance']::market.org_role[], 'invoice.paid',
                            market.campaign_ref(inv.campaign_id) || finance.amount_ref(idr, p_amount)
                            || jsonb_build_object('invoice_id', inv.id, 'number', inv.number, 'kind', inv.kind));
end $function$;

CREATE OR REPLACE FUNCTION api.control_campaign (
  p_campaign uuid,
  p_action   text,
  p_params   jsonb DEFAULT '{}'::jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  prm jsonb := coalesce(p_params, '{}');
  c market.campaigns;
  r market.rate_rules;
  newp jsonb;
  t timestamptz := clock_timestamp();
  new_deadline timestamptz;
  e jsonb;
  items jsonb := '[]';
  sub numeric := 0;
  pl record;
begin
  select * into c from market.campaigns where id = p_campaign for update;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  -- §4: topup = billing (brand_finance) tapi kontrak juga memberi brand_manager.
  if not ops.is_org_member(c.org_id, variadic case when p_action = 'topup'
                                                   then array['brand_owner', 'brand_manager', 'brand_finance']
                                                   else array['brand_owner', 'brand_manager'] end::market.org_role[]) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  if c.is_template then
    perform market.fail('invalid:template', 'template bukan campaign berjalan');
  end if;

  if p_action = 'pause' then
    if c.status <> 'live' then
      perform market.fail('invalid_state:' || c.status, 'hanya campaign live yang bisa dijeda');
    end if;
    update market.campaigns set status = 'paused' where id = c.id;
  elsif p_action = 'resume' then
    if c.status <> 'paused' then
      perform market.fail('invalid_state:' || c.status, 'hanya campaign paused yang bisa dilanjutkan');
    end if;
    if c.submit_deadline <= now() then
      perform market.fail('deadline_passed', 'perpanjang deadline dulu');
    end if;
    update market.campaigns set status = 'live' where id = c.id;
  elsif p_action = 'extend' then
    new_deadline := (prm ->> 'submit_deadline')::timestamptz;
    if c.status not in ('scheduled', 'live', 'paused') then
      perform market.fail('invalid_state:' || c.status, 'perpanjang hanya untuk campaign terjadwal/berjalan');
    end if;
    if new_deadline is null or new_deadline <= greatest(now(), c.submit_deadline) then
      perform market.fail('invalid:submit_deadline', 'deadline baru harus setelah deadline lama');
    end if;
    update market.campaigns set submit_deadline = new_deadline where id = c.id;
  elsif p_action = 'raise_rate' then
    if c.status not in ('scheduled', 'live', 'paused') then
      perform market.fail('invalid_state:' || c.status, 'naikkan rate hanya untuk campaign terjadwal/berjalan');
    end if;
    select * into r from market.rate_rules x
     where x.id = (prm ->> 'rule_id')::uuid and x.campaign_id = c.id and (x.effective_to is null or x.effective_to > now())
       for update;
    if r.id is null then
      perform market.fail('invalid:rule_id', 'rule aktif tidak ditemukan');
    end if;
    newp := prm -> 'params';
    perform market.check_rule_params(r.kind, newp);
    if not (case r.kind
             when 'per_1k_views' then market.jnum(newp -> 'rate') > market.jnum(r.params -> 'rate')
             when 'flat_per_post' then market.jnum(newp -> 'amount') > market.jnum(r.params -> 'amount')
             when 'milestone_bonus' then market.jnum(newp -> 'amount') > market.jnum(r.params -> 'amount')
                                         and market.jnum(newp -> 'threshold') <= market.jnum(r.params -> 'threshold')
             else jsonb_array_length(newp -> 'tiers') = jsonb_array_length(r.params -> 'tiers') and newp <> r.params
                  and not exists (select 1 from generate_series(0, jsonb_array_length(newp -> 'tiers') - 1) i
                                  where market.jnum(newp -> 'tiers' -> i -> 'rate') < market.jnum(r.params -> 'tiers' -> i -> 'rate')
                                     or market.jnum(newp -> 'tiers' -> i -> 'from') <> market.jnum(r.params -> 'tiers' -> i -> 'from'))
           end) then
      perform market.fail('invalid:rate_not_higher', 'rate baru harus lebih tinggi dari rate lama');
    end if;
    -- Rule lama ditutup, rule baru berlaku untuk views sesudahnya (§10.5).
    update market.rate_rules set effective_to = t where id = r.id;
    insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, platform, params, effective_from)
    values (c.id, r.kind, r.reward_type_id, r.pool_id, r.platform, newp, t);
  elsif p_action = 'topup' then
    if c.status not in ('scheduled', 'live', 'paused') then
      perform market.fail('invalid_state:' || c.status, 'top-up hanya untuk campaign terjadwal/berjalan');
    end if;
    if jsonb_typeof(prm -> 'pools') is distinct from 'array' or jsonb_array_length(prm -> 'pools') = 0 then
      perform market.fail('invalid:pools', 'pools [{pool_id, amount}] wajib');
    end if;
    for e in select jsonb_array_elements(prm -> 'pools') loop
      select x.id, rt.idr_value_per_unit into pl from finance.reward_pools x join market.reward_types rt on rt.id = x.reward_type_id
       where x.id = (e ->> 'pool_id')::uuid and x.campaign_id = c.id;
      if pl.id is null or coalesce(market.jnum(e -> 'amount'), 0) <= 0 then
        perform market.fail('invalid:pool', 'pool campaign ini + amount > 0');
      end if;
      items := items || jsonb_build_array(jsonb_build_object('pool_id', pl.id, 'amount', market.jnum(e -> 'amount')));
      sub := sub + market.jnum(e -> 'amount') * pl.idr_value_per_unit;
    end loop;
    perform finance.issue_invoice(c.org_id, c.id, 'topup', sub, 0, null, items);
  elsif p_action = 'end_early' then
    if c.status in ('live', 'paused') then
      update market.campaigns set status = 'tracking' where id = c.id;
    elsif c.status in ('draft', 'in_review', 'scheduled') then
      update market.campaigns set status = 'cancelled' where id = c.id;
      update finance.invoices set status = 'void' where campaign_id = c.id and status = 'issued';
    else
      perform market.fail('invalid_state:' || c.status, 'campaign sudah selesai');
    end if;
    update market.claims set status = 'released' where campaign_id = c.id and status = 'open';
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.create_org (
  p_name       text,
  p_org_type   text,
  p_legal_name text    DEFAULT NULL::text,
  p_npwp       text    DEFAULT NULL::text,
  p_address    text    DEFAULT NULL::text,
  p_is_agency  boolean DEFAULT false
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  oid uuid;
  npwp text := nullif(regexp_replace(coalesce(p_npwp, ''), '[^0-9]', '', 'g'), '');
begin
  if not coalesce((select (auth.jwt() -> 'consent_ok' ->> 'brand')::boolean), false) then
    perform market.fail('consent_required:brand', 'setujui ToS brand dulu (accounts onboarding?role=brand)');
  end if;
  if not exists (select 1 from market.profiles p where p.id = uid and p.status = 'active') then
    perform market.fail('not_eligible:profile_inactive', 'profil belum ada atau tidak aktif');
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 100 then
    perform market.fail('invalid:name', 'nama 2–100 karakter');
  end if;
  if p_org_type = 'badan' then
    if nullif(btrim(p_legal_name), '') is null then
      perform market.fail('invalid:legal_name', 'badan usaha wajib nama legal');
    end if;
    if npwp is null or npwp !~ '^[0-9]{15,16}$' then
      perform market.fail('invalid:npwp', 'NPWP 15/16 digit');
    end if;
  elsif p_org_type = 'perorangan' then
    if coalesce(p_legal_name, p_npwp, p_address) is not null then
      perform market.fail('invalid:perorangan_pii', 'org perorangan: nama legal/NIK/alamat diambil dari KYC pemilik');
    end if;
  else
    perform market.fail('invalid:org_type', coalesce(p_org_type, 'null'));
  end if;
  insert into market.organizations (name, org_type, legal_name, npwp, address, is_agency, created_by)
  values (btrim(p_name), p_org_type, nullif(btrim(p_legal_name), ''), npwp, nullif(btrim(p_address), ''),
          coalesce(p_is_agency, false), uid)
  returning id into oid;
  insert into market.org_members (org_id, user_id, role, added_by) values (oid, uid, 'brand_owner', uid);
  return oid;
end $function$;

CREATE OR REPLACE FUNCTION api.create_org_invite (
  p_org  uuid,
  p_role market.org_role
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  tok text;
begin
  if not market.is_direct_member(p_org, uid, 'brand_owner') then
    perform market.fail('auth:forbidden', 'hanya brand_owner org ini', '42501');
  end if;
  if p_role is null then
    perform market.fail('invalid:role', 'role wajib');
  end if;
  tok := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
  insert into market.org_invites (org_id, role, token_hash, expires_at, created_by)
  values (p_org, p_role, sha256(convert_to(tok, 'UTF8')), now() + interval '7 days', uid);
  return tok;
end $function$;

CREATE OR REPLACE FUNCTION api.create_payout_batch (
  p_cutoff timestamp with time zone
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  bid uuid;
  n int;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  insert into finance.payout_batches (created_by, cutoff_at) values ((select auth.uid()), coalesce(p_cutoff, now()))
  returning id into bid;
  update finance.payouts set batch_id = bid
   where status = 'requested' and channel = 'batch' and batch_id is null and created_at <= coalesce(p_cutoff, now());
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'batch_empty' using errcode = 'P0001';
  end if;
  update finance.payout_batches b set count = n,
         total = (select sum(p.amount - p.fee) from finance.payouts p where p.batch_id = bid)
   where b.id = bid;
  return bid;
end $function$;

CREATE OR REPLACE FUNCTION api.create_report_link (
  p_campaign uuid,
  p_days     integer DEFAULT 90
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  org uuid;
  tok text;
begin
  if not ops.iss_ok() then
    raise exception 'butuh sesi identity' using errcode = '42501';
  end if;
  select c.org_id into org from market.campaigns c where c.id = p_campaign;
  if org is null or not ops.is_org_member(org, 'brand_owner', 'brand_manager') then
    raise exception 'hanya brand_owner atau brand_manager org ini' using errcode = '42501';
  end if;
  tok := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
  insert into market.report_links (campaign_id, token_hash, created_by, expires_at)
  values (p_campaign, sha256(convert_to(tok, 'UTF8')), (select auth.uid()),
          case when p_days is not null then now() + make_interval(days => p_days) end);
  return tok;
end $function$;

CREATE OR REPLACE FUNCTION api.duplicate_campaign (
  p_campaign    uuid,
  p_as_template boolean DEFAULT false
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  nid uuid := gen_random_uuid();
  pl record;
  npid uuid;
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  insert into market.campaigns (id, org_id, slug, title, type, category_id, platforms, brief, required_hashtags, required_mentions,
                                required_links, sponsored_label, min_duration_sec, max_duration_sec, dos, donts, example_urls, faq,
                                view_window_days, review_mode, min_followers, min_account_age_days, min_trust_score, kyc_required,
                                min_views, max_clips_per_clipper, clipper_quota, allow_video_reuse, visibility, is_template,
                                fee_rule_id, created_by)
  values (nid, c.org_id, left(regexp_replace(c.slug, '-[0-9a-f]{6}$', ''), 72) || '-' || substr(md5(nid::text), 1, 6),
          c.title, c.type, c.category_id, c.platforms, c.brief, c.required_hashtags, c.required_mentions, c.required_links,
          c.sponsored_label, c.min_duration_sec, c.max_duration_sec, c.dos, c.donts, c.example_urls, c.faq, c.view_window_days,
          c.review_mode, c.min_followers, c.min_account_age_days, c.min_trust_score, c.kyc_required, c.min_views,
          c.max_clips_per_clipper, c.clipper_quota, c.allow_video_reuse, c.visibility, coalesce(p_as_template, false),
          c.fee_rule_id, uid);
  for pl in select * from finance.reward_pools x where x.campaign_id = c.id order by x.id loop
    insert into finance.reward_pools (campaign_id, reward_type_id, total, max_per_clip)
    values (nid, pl.reward_type_id, pl.total, pl.max_per_clip)
    returning id into npid;
    insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, platform, params)
    select nid, r.kind, r.reward_type_id, npid, r.platform, r.params from market.rate_rules r
     where r.pool_id = pl.id and r.effective_to is null;
  end loop;
  return nid;
end $function$;

CREATE OR REPLACE FUNCTION api.ensure_profile (
  p_username      text,
  p_display_name  text,
  p_referral_code text DEFAULT NULL::text
)
  RETURNS TABLE (
    id           uuid,
    username     text,
    display_name text,
    created      boolean
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  was_new boolean;
begin
  if uid is null or not ops.iss_ok() then
    raise exception 'butuh sesi identity' using errcode = '42501';
  end if;
  begin
    insert into market.profiles as p (id, username, display_name)
    values (uid, lower(btrim(p_username)), btrim(p_display_name))
    on conflict on constraint profiles_pkey do update set username = excluded.username, display_name = excluded.display_name
      where p.status = 'active'
    returning (xmax = 0) into was_new;
  exception when unique_violation then
    raise exception 'username % sudah dipakai', lower(btrim(p_username)) using errcode = '23505';
  end;
  if was_new is null then
    raise exception 'akun tidak aktif' using errcode = '42501';
  end if;
  -- Referral (F-C16) hanya dicatat untuk profil baru; kode tidak dikenal atau milik sendiri diabaikan.
  if was_new and p_referral_code is not null then
    insert into market.referrals (referred_id, referrer_id, code)
    select uid, r.id, r.referral_code from market.profiles r
     where r.referral_code = lower(btrim(p_referral_code)) and r.id <> uid;
  end if;
  return query select pr.id, pr.username, pr.display_name, was_new from market.profiles pr where pr.id = uid;
end $function$;

CREATE OR REPLACE FUNCTION api.invite_to_campaign (
  p_campaign  uuid,
  p_usernames text[]
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  pr record;
  n int := 0;
  k int;
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  if c.is_template or c.status in ('cancelled', 'rejected', 'settling', 'settled') then
    perform market.fail('invalid_state:' || c.status, 'campaign ini tidak bisa menerima undangan');
  end if;
  if coalesce(cardinality(p_usernames), 0) > 500 then
    perform market.fail('invalid:usernames', 'maks 500 username per panggilan');
  end if;
  for pr in select p.id from market.profiles p
             where p.status = 'active'
               and p.username in (select lower(btrim(ltrim(btrim(u), '@'))) from unnest(p_usernames) u) loop
    insert into market.campaign_invites (campaign_id, user_id, invited_by) values (c.id, pr.id, uid) on conflict do nothing;
    get diagnostics k = row_count;
    if k > 0 then
      n := n + 1;
      perform ops.enqueue_notification(pr.id, 'campaign.invited',
                                       jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'campaign_slug', c.slug,
                                                          'org_id', c.org_id,
                                                          'org_name', (select o.name from market.organizations o where o.id = c.org_id)));
    end if;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION api.link_agency (
  p_agency uuid,
  p_client uuid,
  p_action text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  l market.org_links;
begin
  select * into l from market.org_links where agency_org_id = p_agency and client_org_id = p_client for update;
  if p_action = 'request' then
    if not market.is_direct_member(p_agency, uid, 'brand_owner', 'brand_manager') then
      perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org agency', '42501');
    end if;
    if not exists (select 1 from market.organizations o where o.id = p_agency and o.is_agency) then
      perform market.fail('not_agency', 'org ini bukan agency');
    end if;
    if not exists (select 1 from market.organizations o where o.id = p_client) or p_client = p_agency then
      perform market.fail('not_found:org', null, 'P0002');
    end if;
    if l.agency_org_id is not null and l.revoked_at is null then
      perform market.fail('already_linked', case when l.approved_at is null then 'menunggu persetujuan klien' else 'sudah tertaut' end);
    end if;
    insert into market.org_links (agency_org_id, client_org_id) values (p_agency, p_client)
    on conflict (agency_org_id, client_org_id) do update
      set approved_by = null, approved_at = null, revoked_at = null, created_at = now();
    perform market.notify_org(p_client, array['brand_owner']::market.org_role[], 'agency.link_requested',
                              jsonb_build_object('agency_org_id', p_agency,
                                                 'agency_org_name', (select o.name from market.organizations o where o.id = p_agency)));
  elsif p_action = 'approve' then
    if not market.is_direct_member(p_client, uid, 'brand_owner') then
      perform market.fail('auth:forbidden', 'butuh brand_owner org klien', '42501');
    end if;
    if l.agency_org_id is null or l.revoked_at is not null or l.approved_at is not null then
      perform market.fail('invalid_state:link', 'tidak ada permintaan yang menunggu');
    end if;
    update market.org_links set approved_by = uid, approved_at = now()
     where agency_org_id = p_agency and client_org_id = p_client;
    perform market.notify_org(p_agency, array['brand_owner', 'brand_manager']::market.org_role[], 'agency.link_approved',
                              jsonb_build_object('client_org_id', p_client,
                                                 'client_org_name', (select o.name from market.organizations o where o.id = p_client)));
  elsif p_action in ('revoke', 'reject') then
    if not (market.is_direct_member(p_client, uid, 'brand_owner') or market.is_direct_member(p_agency, uid, 'brand_owner')) then
      perform market.fail('auth:forbidden', 'butuh brand_owner klien atau agency', '42501');
    end if;
    if l.agency_org_id is null or l.revoked_at is not null then
      perform market.fail('invalid_state:link', 'tautan tidak aktif');
    end if;
    update market.org_links set revoked_at = now() where agency_org_id = p_agency and client_org_id = p_client;
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.list_campaigns (
  p_filters jsonb DEFAULT '{}'::jsonb,
  p_cursor  text  DEFAULT NULL::text
)
  RETURNS TABLE (
    id                  uuid,
    slug                text,
    title               text,
    type                text,
    category_id         text,
    status              market.campaign_status,
    platforms           market.platform[],
    visibility          text,
    start_at            timestamp with time zone,
    submit_deadline     timestamp with time zone,
    cover_path          text,
    is_pinned           boolean,
    pinned_rank         smallint,
    is_new              boolean,
    rates               jsonb,
    budget_idr          numeric,
    remaining_idr       numeric,
    est_remaining_views jsonb,
    cta_state           text,
    cta_reason          text,
    next_cursor         text
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
#variable_conflict use_column
declare
  uid uuid := (select auth.uid());
  f jsonb := coalesce(p_filters, '{}');
  v_sort text := coalesce(f ->> 'sort', 'newest');
  v_limit int := least(greatest(coalesce(market.jnum(f -> 'limit')::int, 20), 1), 50);
  v_q text := nullif(lower(btrim(f ->> 'q')), '');
  v_platform market.platform := nullif(f ->> 'platform', '')::market.platform;
  v_category text := nullif(f ->> 'category', '');
  pub constant market.campaign_status[] := array['live', 'paused', 'tracking', 'exhausted', 'settling', 'settled']::market.campaign_status[];
  v_status market.campaign_status[] := array['live', 'paused']::market.campaign_status[];
  new_days int := coalesce((select (s.value #>> '{}')::int from ops.settings s where s.key = 'public.market.new_badge_days'), 3);
  cur text[];
  cg int;
  cr int;
  ck numeric;
  cid uuid;
begin
  if uid is not null and not ops.iss_ok() then
    perform market.fail('auth:no_session', 'butuh sesi identity', '42501');
  end if;
  if v_sort not in ('newest', 'rate', 'budget', 'deadline') then
    perform market.fail('invalid:sort', v_sort);
  end if;
  if jsonb_typeof(f -> 'status') = 'array' then
    v_status := array(select jsonb_array_elements_text(f -> 'status'))::market.campaign_status[];
  elsif f ->> 'status' = 'all' then
    v_status := pub;
  elsif nullif(f ->> 'status', '') is not null then
    v_status := array[(f ->> 'status')::market.campaign_status];
  end if;
  if p_cursor is not null then
    cur := string_to_array(p_cursor, '|');
    begin
      cg := cur[1]::int; cr := cur[2]::int; ck := cur[3]::numeric; cid := cur[4]::uuid;
    exception when others then
      perform market.fail('invalid:cursor', p_cursor);
    end;
    if cardinality(cur) <> 4 or cid is null then
      perform market.fail('invalid:cursor', p_cursor);
    end if;
  end if;

  return query
  with base as (
    select c.id, c.slug, c.title, c.type, c.category_id, c.status, c.platforms, c.visibility, c.start_at, c.submit_deadline,
           c.created_at, c.pinned_rank, coalesce(c.pinned_until > now(), false) as pinned,
           (select coalesce(sum((pl.total - pl.allocated) * rt.idr_value_per_unit), 0)
              from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
             where pl.campaign_id = c.id) as rem_idr,
           (select max(x.s) from (select sum(market.rule_rate(r.kind, r.params) * rt.idr_value_per_unit) as s
                                    from unnest(c.platforms) pf(p)
                                    join market.rate_rules r on r.campaign_id = c.id and (r.platform is null or r.platform = pf.p)
                                     and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
                                    join market.reward_types rt on rt.id = r.reward_type_id
                                   group by pf.p) x) as rate_idr
      from market.campaigns c
     where c.status = any (v_status) and c.status = any (pub) and not c.is_template
       and (c.visibility = 'public' or market.campaign_visible(c))
       and (v_platform is null or v_platform = any (c.platforms))
       and (v_category is null or c.category_id = v_category)
       and (v_q is null or position(v_q in lower(c.title)) > 0 or ltrim(v_q, '#') = any (c.required_hashtags))
  ), keyed as (
    select b.*, case when b.pinned then 0 else 1 end as g,
           case when b.pinned then coalesce(b.pinned_rank, 32767) else 32767 end::int as r,
           case v_sort when 'newest' then -extract(epoch from coalesce(b.start_at, b.created_at))
                       when 'rate' then -coalesce(b.rate_idr, 0)
                       when 'budget' then -b.rem_idr
                       else coalesce(extract(epoch from b.submit_deadline), 1e12) end as k
      from base b
  ), page as (
    select kk.* from keyed kk
     where p_cursor is null or (kk.g, kk.r, kk.k, kk.id) > (cg, cr, ck, cid)
     order by kk.g, kk.r, kk.k, kk.id
     limit v_limit
  )
  select pg.id, pg.slug, pg.title, pg.type, pg.category_id, pg.status, pg.platforms, pg.visibility, pg.start_at, pg.submit_deadline,
         (select a.storage_path from market.campaign_assets a where a.campaign_id = pg.id and a.kind = 'cover'
           order by a.created_at limit 1),
         pg.pinned, case when pg.pinned then pg.pinned_rank end, coalesce(pg.start_at, pg.created_at) > now() - make_interval(days => new_days),
         bb.bud -> 'rates', (bb.bud ->> 'budget_idr')::numeric, trim_scale(round(pg.rem_idr, 2)), bb.bud -> 'est_remaining_views',
         cc.state, cc.reason, concat_ws('|', pg.g, pg.r, pg.k, pg.id)
    from page pg
    cross join lateral (select market.campaign_budget(pg.id) as bud) bb
    cross join lateral market.claim_check(pg.id) cc
   order by pg.g, pg.r, pg.k, pg.id;
end $function$;

CREATE OR REPLACE FUNCTION api.manage_org (
  p_org    uuid,
  p_action text,
  p_params jsonb DEFAULT '{}'::jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  prm jsonb := coalesce(p_params, '{}');
  o market.organizations;
  member_id uuid;
  member_role market.org_role;
  old_role market.org_role;
  new_rule uuid;
begin
  if not ops.has_admin('admin_ops') then
    perform market.fail('auth:forbidden', 'butuh admin_ops/admin_super aal2', '42501');
  end if;
  select * into o from market.organizations where id = p_org;
  if o.id is null then
    perform market.fail('not_found:org', null, 'P0002');
  end if;
  if p_action = 'verify' then
    perform market.decide_org(o.id, 'approve', uid, prm ->> 'reason', prm ->> 'message', prm ->> 'note');
  elsif p_action = 'reject' then
    perform market.decide_org(o.id, 'reject', uid, prm ->> 'reason', prm ->> 'message', prm ->> 'note');
  elsif p_action = 'suspend' then
    if nullif(btrim(prm ->> 'reason'), '') is null then
      perform market.fail('invalid:reason', 'suspend wajib alasan');
    end if;
    update market.organizations set status = 'suspended' where id = o.id;
    perform market.notify_org(o.id, null, 'org.suspended', jsonb_build_object('reason', prm ->> 'reason', 'message', prm ->> 'message'));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'org.suspend', 'org:' || o.id, jsonb_build_object('status', o.status),
            jsonb_build_object('status', 'suspended', 'reason', prm ->> 'reason'));
  elsif p_action = 'set_fee' then
    if jsonb_typeof(prm) = 'null' or prm = '{}'::jsonb or coalesce((prm ->> 'clear')::boolean, false) then
      new_rule := null;
    else
      new_rule := finance.create_fee_rule('org', prm, finance.effective_fee_rule(null, null), uid);
    end if;
    update market.organizations set fee_rule_id = new_rule where id = o.id;
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'org.set_fee', 'org:' || o.id,
            (select to_jsonb(f) from finance.fee_rules f where f.id = o.fee_rule_id),
            (select to_jsonb(f) from finance.fee_rules f where f.id = new_rule));
  elsif p_action = 'add_member' then
    member_id := (prm ->> 'user_id')::uuid;
    member_role := coalesce((prm ->> 'role')::market.org_role, 'brand_owner');
    if member_id is null then
      perform market.fail('invalid:user_id', 'user_id identity wajib');
    end if;
    perform market.ensure_member_profile(member_id, prm ->> 'username', prm ->> 'display_name');
    select m.role into old_role from market.org_members m where m.org_id = o.id and m.user_id = member_id;
    insert into market.org_members (org_id, user_id, role, added_by) values (o.id, member_id, member_role, uid)
    on conflict (org_id, user_id) do update set role = excluded.role;
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'org.add_member', 'org:' || o.id, jsonb_build_object('user_id', member_id, 'role', old_role),
            jsonb_build_object('user_id', member_id, 'role', member_role));
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.mark_batch_paid (
  p_batch   uuid,
  p_results jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  b finance.payout_batches;
  x record;
  po finance.payouts;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into b from finance.payout_batches pb where pb.id = p_batch for update;
  if not found or b.status not in ('exported', 'paid', 'closed') then
    raise exception 'batch_not_exported' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_results) is distinct from 'array' then
    raise exception 'invalid:results' using errcode = 'P0001';
  end if;
  for x in select * from jsonb_to_recordset(p_results) r(payout_id uuid, status text, bank_ref text) loop
    select * into po from finance.payouts p where p.id = x.payout_id and p.batch_id = p_batch for update;
    if not found then
      raise exception 'payout_not_in_batch' using errcode = 'P0001';
    end if;
    continue when (po.status = 'paid' and x.status = 'paid') or (po.status = 'returned' and x.status = 'failed');
    if po.status <> 'processing' and not (po.status = 'paid' and x.status = 'failed') then  -- paid → failed = retur bank
      raise exception 'payout_not_in_export' using errcode = 'P0001';
    end if;
    if x.status = 'paid' then
      update finance.payouts set status = 'paid', paid_at = now(), bank_ref = x.bank_ref where id = po.id;
      perform ops.enqueue_notification(po.user_id, 'payout.paid', finance.amount_ref(finance.idr(), po.amount - po.fee)
                                       || jsonb_build_object('payout_id', po.id, 'channel', po.channel));
    elsif x.status = 'failed' then
      update finance.payouts set bank_ref = x.bank_ref where id = po.id;
      perform finance.return_payout(po.id);
    else
      raise exception 'invalid:result_status' using errcode = 'P0001';
    end if;
  end loop;
  if not exists (select 1 from finance.payouts p where p.batch_id = p_batch and p.status = 'processing') and b.status = 'exported' then
    update finance.payout_batches set status = 'paid', executed_at = now() where id = p_batch;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.missing_brief_tags (
  p_campaign uuid,
  p_caption  text
)
  RETURNS text[]
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
declare
  c record;
  cap text := lower(coalesce(p_caption, ''));
  tags text[];
  handles text[];
  missing text[] := '{}';
  x text;
begin
  select required_hashtags, required_mentions, required_links into c from api.campaigns where id = p_campaign;
  if not found then
    return null;
  end if;
  select coalesce(array_agg(m[1]), '{}') into tags from regexp_matches(cap, '#([[:alnum:]_]+)', 'g') m;
  select coalesce(array_agg(rtrim(m[1], '.')), '{}') into handles from regexp_matches(cap, '@([[:alnum:]_.]+)', 'g') m;
  foreach x in array c.required_hashtags loop
    if not (x = any (tags)) then
      missing := missing || ('#' || x);
    end if;
  end loop;
  foreach x in array c.required_mentions loop
    if not (x = any (handles)) then
      missing := missing || ('@' || x);
    end if;
  end loop;
  foreach x in array c.required_links loop
    if position(lower(regexp_replace(regexp_replace(x, '^https://(www\.)?', ''), '/+$', '')) in cap) = 0 then
      missing := missing || x;
    end if;
  end loop;
  return missing;
end $function$;

CREATE OR REPLACE FUNCTION api.my_referral_code()
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  code text;
begin
  if uid is null or not ops.iss_ok() then
    raise exception 'butuh sesi identity' using errcode = '42501';
  end if;
  select p.referral_code into code from market.profiles p where p.id = uid;
  while code is null loop
    begin
      update market.profiles set referral_code = substr(md5(extensions.gen_random_bytes(16)::text), 1, 8)
       where id = uid returning referral_code into code;
      if not found then
        raise exception 'profil belum ada' using errcode = 'P0002';
      end if;
    exception when unique_violation then
      code := null;
    end;
  end loop;
  return code;
end $function$;

CREATE OR REPLACE FUNCTION api.my_stats()
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  approved int;
  rejected int;
begin
  select count(*) filter (where s.status in ('tracking', 'flagged', 'forfeited', 'locked', 'settled')),
         count(*) filter (where s.status in ('rejected', 'rejected_final'))
    into approved, rejected
    from tracking.submissions s where s.user_id = uid;
  return jsonb_build_object(
    'trust_score', (select p.trust_score from market.profiles p where p.id = uid),
    'status', (select p.status from market.profiles p where p.id = uid),
    'total_views', coalesce((select sum(s.counted_views) from tracking.submissions s where s.user_id = uid
                             and s.status in ('tracking', 'flagged', 'locked', 'settled')), 0),
    'clips', (select count(*) from tracking.submissions s where s.user_id = uid),
    'campaigns', (select count(distinct s.campaign_id) from tracking.submissions s where s.user_id = uid),
    'approved', approved,
    'rejected', rejected,
    'approval_rate', case when approved + rejected > 0 then round(approved::numeric / (approved + rejected) * 100, 1) end,
    'earnings', coalesce((select jsonb_agg(jsonb_build_object('reward_type_id', x.reward_type_id, 'code', rt.code,
                                                              'unit_label', rt.unit_label, 'decimals', rt.decimals,
                                                              'pending', trim_scale(x.pending), 'available', trim_scale(x.available),
                                                              'withdrawn', trim_scale(x.withdrawn),
                                                              'total', trim_scale(x.pending + x.available + x.withdrawn))
                                           order by rt.code)
                            from (select e.reward_type_id,
                                         coalesce(sum(e.amount) filter (where e.state = 'pending'), 0) as pending,
                                         coalesce(sum(e.amount) filter (where e.state = 'available'), 0) as available,
                                         coalesce(sum(e.amount) filter (where e.state = 'withdrawn'), 0) as withdrawn
                                    from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                                   where a.owner_type = 'user_wallet' and a.owner_id = uid
                                   group by e.reward_type_id) x
                            join market.reward_types rt on rt.id = x.reward_type_id), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION api.record_review (
  p_target_type text,
  p_target_id   uuid,
  p_decision    text,
  p_reason      text DEFAULT NULL::text,
  p_message     text DEFAULT NULL::text,
  p_note        text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  s record;
  is_admin boolean;
begin
  if p_target_type = 'campaign' then
    if not ops.has_admin('admin_ops') then
      perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
    end if;
    select * into c from market.campaigns where id = p_target_id for update;
    if c.id is null then
      perform market.fail('not_found:campaign', null, 'P0002');
    end if;
    if c.status <> 'in_review' then
      perform market.fail('invalid_state:' || c.status, 'hanya campaign in_review yang bisa direview');
    end if;
    if p_decision = 'approve' then
      if not exists (select 1 from finance.invoices i where i.campaign_id = c.id and i.kind = 'campaign' and i.status = 'paid') then
        perform market.fail('invoice_unpaid', 'invoice campaign belum lunas');
      end if;
      update market.campaigns set status = 'scheduled' where id = c.id;
    elsif p_decision = 'reject' then
      if nullif(btrim(p_reason), '') is null then
        perform market.fail('invalid:reason', 'penolakan wajib alasan');
      end if;
      update market.campaigns set status = 'rejected' where id = c.id;
    else
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
    values ('campaign', c.id, uid, p_decision, p_reason, p_message, p_note);
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[],
                              case p_decision when 'approve' then 'campaign.approved' else 'campaign.rejected' end,
                              jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'reason', p_reason, 'message', p_message));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'review.campaign.' || p_decision, 'campaign:' || c.id, jsonb_build_object('status', c.status),
            jsonb_build_object('status', case p_decision when 'approve' then 'scheduled' else 'rejected' end, 'reason', p_reason));

  elsif p_target_type = 'submission' then
    if p_decision not in ('approve', 'reject', 'overturn', 'uphold') then
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    select sb.id, sb.status, k.org_id, k.review_mode into s
      from tracking.submissions sb join market.campaigns k on k.id = sb.campaign_id where sb.id = p_target_id;
    if s.id is null then
      perform market.fail('not_found:submission', null, 'P0002');
    end if;
    is_admin := ops.has_admin('admin_moderator');
    if not is_admin and not (s.review_mode = 'brand' and s.status = 'in_review'
                             and ops.is_org_member(s.org_id, 'brand_owner', 'brand_manager')) then
      perform market.fail('auth:forbidden', 'butuh admin_moderator aal2 atau brand_owner/brand_manager (review brand)', '42501');
    end if;
    perform trust.apply_submission_decision(s.id, p_decision, uid, p_reason, p_message, p_note);
    if is_admin then
      insert into ops.audit_logs (actor_id, action, target, before, after)
      values (uid, 'review.submission.' || p_decision, 'submission:' || s.id, jsonb_build_object('status', s.status),
              jsonb_build_object('status', (select x.status from tracking.submissions x where x.id = s.id), 'reason', p_reason));
    end if;

  elsif p_target_type = 'kyc' then
    -- Keputusan KYC diputus di identity (admin_kyc_decision); core hanya mencatat (tanpa PII) + mengabari user.
    if not ops.has_admin('admin_moderator') then
      perform market.fail('auth:forbidden', 'butuh admin_moderator aal2', '42501');
    end if;
    if p_decision not in ('approve', 'reject') then
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    if p_decision = 'reject' and nullif(btrim(p_reason), '') is null then
      perform market.fail('invalid:reason', 'penolakan wajib alasan');
    end if;
    if not exists (select 1 from market.profiles pr where pr.id = p_target_id) then
      perform market.fail('not_found:profile', null, 'P0002');
    end if;
    insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
    values ('kyc', p_target_id, uid, p_decision, p_reason, p_message, p_note);
    perform ops.enqueue_notification(p_target_id, case p_decision when 'approve' then 'kyc.approved' else 'kyc.rejected' end,
                                     jsonb_build_object('decision', p_decision, 'reason', p_reason, 'message', p_message));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'review.kyc.' || p_decision, 'profile:' || p_target_id, null, jsonb_build_object('reason', p_reason));

  elsif p_target_type = 'org' then
    if not ops.has_admin('admin_ops') then
      perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
    end if;
    if p_decision not in ('approve', 'reject') then
      perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
    end if;
    perform market.decide_org(p_target_id, p_decision, uid, p_reason, p_message, p_note);
  else
    perform market.fail('invalid:target_type', coalesce(p_target_type, 'null'));
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.report_by_token (
  p_token text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  cid uuid;
begin
  select rl.campaign_id into cid from market.report_links rl
   where rl.token_hash = sha256(convert_to(p_token, 'UTF8')) and rl.revoked_at is null
     and (rl.expires_at is null or rl.expires_at > now());
  if cid is null then
    return null;
  end if;
  return market.campaign_report(cid);
end $function$;

CREATE OR REPLACE FUNCTION api.request_fulfillment (
  p_reward_type   uuid,
  p_amount        numeric,
  p_recipient     jsonb,
  p_recipient_ref uuid,
  p_idempotency   text
)
  RETURNS finance.fulfillments
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pr market.profiles := finance.require_active_clipper();
  rt market.reward_types;
  res finance.fulfillments;
  wallet uuid;
  rec jsonb := coalesce(p_recipient, '{}');
begin
  if p_idempotency is null or length(p_idempotency) < 8 then
    raise exception 'invalid:idempotency' using errcode = 'P0001';
  end if;
  select * into res from finance.fulfillments f where f.idempotency_key = p_idempotency;
  if found then
    if res.user_id <> pr.id then
      raise exception 'idempotency_conflict' using errcode = 'P0001';
    end if;
    return res;
  end if;
  select * into rt from market.reward_types t where t.id = p_reward_type;
  if not found or rt.fulfillment = 'payout' then
    raise exception 'invalid:reward_type' using errcode = 'P0001';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> trunc(p_amount, rt.decimals)
     or (rt.fulfillment = 'code_pool' and p_amount <> 1) then
    raise exception 'invalid:amount' using errcode = 'P0001';
  end if;
  if jsonb_typeof(rec) <> 'object' then
    raise exception 'invalid:recipient' using errcode = 'P0001';
  end if;
  if exists (select 1 from jsonb_array_elements(rt.recipient_schema) f
             where coalesce((f ->> 'pii')::boolean, false) and rec ? (f ->> 'key')) then
    raise exception 'pii_in_recipient' using errcode = 'P0001';
  end if;
  if p_recipient_ref is null and exists (select 1 from jsonb_array_elements(rt.recipient_schema) f
                                         where coalesce((f ->> 'pii')::boolean, false)) then
    raise exception 'recipient_ref_required' using errcode = 'P0001';
  end if;
  if exists (select 1 from jsonb_array_elements(rt.recipient_schema) f
             where not coalesce((f ->> 'pii')::boolean, false) and coalesce((f ->> 'required')::boolean, true)
               and coalesce(rec ->> (f ->> 'key'), '') = '') then
    raise exception 'recipient_incomplete' using errcode = 'P0001';
  end if;

  wallet := finance.account('user_wallet', pr.id, rt.id);
  perform 1 from finance.ledger_accounts a where a.id = wallet for update;
  if finance.balance(wallet, 'available') < p_amount then
    raise exception 'insufficient_balance' using errcode = 'P0001';
  end if;
  insert into finance.fulfillments (user_id, reward_type_id, amount, recipient, recipient_ref, idempotency_key)
  values (pr.id, rt.id, p_amount, rec, p_recipient_ref, p_idempotency) returning * into res;
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(wallet, -p_amount, 'fulfillment', res.id::text, 'available'),
    finance.e(wallet, p_amount, 'fulfillment', res.id::text, 'withdrawn')));
  return res;
end $function$;

CREATE OR REPLACE FUNCTION api.request_payout (
  p_method      uuid,
  p_amount      numeric,
  p_channel     text,
  p_idempotency text
)
  RETURNS finance.payouts
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pr market.profiles := finance.require_active_clipper();
  idr uuid := finance.idr();
  res finance.payouts;
  wallet uuid;
  fee numeric := 0;
  bonus_days int := (ops.cfg('finance.referral_bonus_days', '90'))::int;
begin
  if coalesce(auth.jwt() ->> 'kyc', '') <> 'approved' then
    raise exception 'auth:kyc_required' using errcode = '42501';
  end if;
  if p_idempotency is null or length(p_idempotency) < 8 then
    raise exception 'invalid:idempotency' using errcode = 'P0001';
  end if;
  select * into res from finance.payouts p where p.idempotency_key = p_idempotency;
  if found then
    if res.user_id <> pr.id then
      raise exception 'idempotency_conflict' using errcode = 'P0001';
    end if;
    return res;  -- replay: tidak memotong saldo dua kali
  end if;
  if p_method is null then
    raise exception 'invalid:method' using errcode = 'P0001';
  end if;
  if p_channel is null or p_channel not in ('batch', 'instant') then
    raise exception 'invalid:channel' using errcode = 'P0001';
  end if;
  if exists (select 1 from trust.fraud_flags f where f.target_type = 'profile' and f.target_id = pr.id and f.status in ('open', 'held')) then
    raise exception 'payout_blocked' using errcode = 'P0001';  -- FR-04/FR-05: blok withdraw sampai direview
  end if;
  if p_amount is null or p_amount <> trunc(p_amount) then
    raise exception 'invalid:amount' using errcode = 'P0001';
  end if;
  if p_amount < (ops.cfg('public.finance.min_withdraw_idr', '100000'))::numeric then
    raise exception 'below_minimum' using errcode = 'P0001';
  end if;
  if p_channel = 'instant' then
    if not coalesce((ops.cfg('public.flags.instant_withdraw', 'false'))::boolean, false) then
      raise exception 'instant_disabled' using errcode = 'P0001';
    end if;
    if pr.trust_score < (ops.cfg('public.finance.instant_min_trust', '70'))::int then
      raise exception 'trust_too_low' using errcode = 'P0001';
    end if;
    fee := coalesce((select fr.instant_withdraw_fee from finance.fee_rules fr where fr.scope = 'global'), 0);
    if fee >= p_amount then
      raise exception 'below_minimum' using errcode = 'P0001';
    end if;
  end if;

  wallet := finance.account('user_wallet', pr.id, idr);
  perform 1 from finance.ledger_accounts a where a.id = wallet for update;  -- serialkan withdraw per user
  if finance.balance(wallet, 'available') < p_amount then
    raise exception 'insufficient_balance' using errcode = 'P0001';
  end if;

  insert into finance.payouts (user_id, method_id, amount, fee, channel, idempotency_key)
  values (pr.id, p_method, p_amount, fee, p_channel, p_idempotency) returning * into res;
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(wallet, -p_amount, 'payout', res.id::text, 'available'),
    finance.e(wallet, p_amount - fee, 'payout', res.id::text, 'withdrawn'),
    finance.e(finance.account('platform_revenue', null, idr), fee, 'fee', res.id::text)));

  -- Referral (F-C16) mulai berlaku saat core pertama kali melihat KYC approved user ini.
  update market.referrals set qualified_at = now(), bonus_until = now() + make_interval(days => bonus_days)
   where referred_id = pr.id and qualified_at is null;

  if p_channel = 'instant' then
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'disburse', 'payout_id', res.id));
  end if;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION api.request_refund (
  p_org         uuid,
  p_campaign    uuid,
  p_mode        text,
  p_amount      numeric,
  p_idempotency text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  idr uuid := finance.idr();
  c market.campaigns;
  credit uuid;
  rid uuid;
  left_total numeric := 0;
  need numeric;
  take numeric;
  ref text;
  x record;
  entries jsonb := '[]';
  fee numeric := (ops.cfg('finance.refund_transfer_fee_idr', '0'))::numeric;
begin
  if uid is null or not ops.iss_ok() then
    raise exception 'auth:no_session' using errcode = '42501';
  end if;
  if not ops.is_org_member(p_org, 'brand_owner', 'brand_finance') or coalesce(auth.jwt() ->> 'aal', '') <> 'aal2' then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if p_mode is null or p_mode not in ('rollover', 'refund') then
    raise exception 'invalid:mode' using errcode = 'P0001';
  end if;
  if p_idempotency is null or length(p_idempotency) < 8 then
    raise exception 'invalid:idempotency' using errcode = 'P0001';
  end if;
  -- Replay: kembalikan hasil yang sama tanpa jurnal baru.
  if p_mode = 'refund' then
    select r.id into rid from finance.org_refunds r where r.idempotency_key = p_idempotency and r.org_id = p_org;
    if rid is not null then
      return rid;
    end if;
  else
    select e.txn_id into rid from finance.ledger_entries e where e.ref_type = 'rollover' and e.ref_id = p_idempotency limit 1;
    if rid is not null then
      return rid;
    end if;
  end if;

  select * into c from market.campaigns k where k.id = p_campaign and k.org_id = p_org;
  if not found then
    raise exception 'not_found:campaign' using errcode = 'P0002';
  end if;
  if c.status not in ('settled', 'cancelled') then
    raise exception 'invalid_state:%', c.status using errcode = 'P0001';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> trunc(p_amount) or (p_mode = 'refund' and p_amount <= fee) then
    raise exception 'invalid:amount' using errcode = 'P0001';
  end if;
  perform 1 from finance.reward_pools rp where rp.campaign_id = c.id order by rp.id for update;
  select coalesce(sum(finance.balance(a.id)), 0) into left_total
    from finance.reward_pools rp join finance.ledger_accounts a on a.owner_type = 'campaign_pool' and a.owner_id = rp.id
   where rp.campaign_id = c.id and rp.reward_type_id = idr;
  if p_amount > left_total then
    raise exception 'insufficient_balance' using errcode = 'P0001', detail = format('sisa %s', left_total);
  end if;

  if p_mode = 'refund' then
    insert into finance.org_refunds (org_id, campaign_id, amount, transfer_fee, requested_by, idempotency_key)
    values (p_org, c.id, p_amount, fee, uid, p_idempotency) returning id into rid;
    ref := rid::text;
  else
    rid := gen_random_uuid();  -- txn id rollover
    ref := p_idempotency;
  end if;
  need := p_amount;
  for x in select a.id as account, finance.balance(a.id) as bal
             from finance.reward_pools rp join finance.ledger_accounts a on a.owner_type = 'campaign_pool' and a.owner_id = rp.id
            where rp.campaign_id = c.id and rp.reward_type_id = idr order by rp.id loop
    exit when need <= 0;
    take := least(need, greatest(x.bal, 0));
    entries := entries || jsonb_build_array(finance.e(x.account, -take, p_mode, ref));
    need := need - take;
  end loop;
  credit := finance.account('org_credit', p_org, idr);
  entries := entries || jsonb_build_array(finance.e(credit, p_amount, p_mode, ref));
  perform finance.post(case when p_mode = 'rollover' then rid else gen_random_uuid() end, entries);
  return rid;
end $function$;

CREATE OR REPLACE FUNCTION api.resolve_alert (
  p_id bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.has_admin() then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  update ops.alerts set resolved_at = now(), resolved_by = (select auth.uid()) where id = p_id and resolved_at is null;
  if not found then
    raise exception 'not_found:alert' using errcode = 'P0002';
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.resolve_fraud_flag (
  p_flag   uuid,
  p_action text,
  p_note   text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  f trust.fraud_flags;
  target_user uuid;
  sub tracking.submissions;
  x record;
  score_delta smallint;
begin
  if not ops.has_admin('admin_moderator') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('hold', 'reverse', 'suspend', 'ban', 'dismiss') then
    raise exception 'invalid:action' using errcode = 'P0001';
  end if;
  select * into f from trust.fraud_flags ff where ff.id = p_flag for update;
  if not found then
    raise exception 'not_found:fraud_flag' using errcode = 'P0002';
  end if;
  if f.status not in ('open', 'held') then
    raise exception 'invalid_state:%', f.status using errcode = 'P0001';
  end if;
  target_user := case f.target_type
    when 'profile' then f.target_id
    when 'submission' then (select s.user_id from tracking.submissions s where s.id = f.target_id)
    when 'social_account' then (select a.user_id from tracking.social_accounts a where a.id = f.target_id)
    when 'payout' then (select p.user_id from finance.payouts p where p.id = f.target_id) end;
  if f.target_type = 'submission' then
    select * into sub from tracking.submissions s where s.id = f.target_id for update;
  end if;
  if p_action = 'reverse' and f.target_type not in ('submission', 'profile') then
    raise exception 'invalid:action_for_target' using errcode = 'P0001';
  end if;

  if p_action = 'hold' then
    update trust.fraud_flags set status = 'held' where id = f.id;
    if sub.status = 'tracking' then
      update tracking.submissions set status = 'flagged' where id = sub.id;
    end if;
    if f.target_type = 'payout' then
      update finance.payouts set status = 'on_hold', hold_reason = 'fraud:' || f.signal where id = f.target_id and status = 'requested';
    end if;
  elsif p_action = 'dismiss' then
    update trust.fraud_flags set status = 'dismissed', resolved_by = uid, resolved_at = now() where id = f.id;
    if sub.status = 'flagged' and not exists (select 1 from trust.fraud_flags o where o.target_type = 'submission'
                                               and o.target_id = sub.id and o.status in ('open', 'held')) then
      update tracking.submissions set status = 'tracking', next_poll_at = coalesce(next_poll_at, now()) where id = sub.id;
    end if;
  else
    update trust.fraud_flags set status = 'actioned', resolved_by = uid, resolved_at = now() where id = f.id;
    if p_action = 'reverse' then
      for x in select s.id, s.status from tracking.submissions s
                where (f.target_type = 'submission' and s.id = f.target_id)
                   or (f.target_type = 'profile' and s.user_id = f.target_id and s.status in ('tracking', 'flagged', 'locked'))
                order by s.id loop
        perform finance.reverse_earning(x.id, 'fraud:' || f.signal);
        if x.status in ('tracking', 'flagged') then
          update tracking.submissions set status = 'forfeited', next_poll_at = null where id = x.id;
          perform ops.enqueue_notification(target_user, 'submission.forfeited',
                                           market.campaign_ref((select s.campaign_id from tracking.submissions s where s.id = x.id))
                                           || jsonb_build_object('submission_id', x.id, 'reason', 'fraud:' || f.signal));
        end if;
      end loop;
    elsif p_action = 'suspend' then
      update market.profiles set status = 'suspended', suspended_until = now() + interval '30 days'
       where id = target_user and status in ('active', 'suspended');
      perform ops.enqueue_notification(target_user, 'account.suspended',
                                       jsonb_build_object('until', now() + interval '30 days', 'signal', f.signal));
    elsif p_action = 'ban' then
      update market.profiles set status = 'banned' where id = target_user and status <> 'closed';
      for x in select s.id, s.status from tracking.submissions s
                where s.user_id = target_user and s.status in ('tracking', 'flagged', 'locked') order by s.id loop
        perform finance.reverse_earning(x.id, 'ban:' || f.signal);  -- pending hangus (§12 sanksi bertingkat)
        if x.status in ('tracking', 'flagged') then
          update tracking.submissions set status = 'forfeited', next_poll_at = null where id = x.id;
        end if;
      end loop;
      update market.claims set status = 'released' where user_id = target_user and status = 'open';
      perform ops.enqueue_notification(target_user, 'account.banned', jsonb_build_object('signal', f.signal, 'flag_id', f.id));
      perform ops.invoke_function('bridge', jsonb_build_object('action', 'ban_user', 'user_id', target_user));
    end if;
  end if;

  score_delta := case p_action when 'reverse' then -10 when 'suspend' then -20 when 'ban' then -50 end;
  if score_delta is not null and target_user is not null then
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by) values (target_user, score_delta, 'fraud_flag', f.id::text, uid);
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'fraud_flag.resolve', 'fraud_flag:' || f.id, jsonb_build_object('status', f.status),
          jsonb_build_object('action', p_action, 'note', p_note, 'target_user', target_user));
end $function$;

CREATE OR REPLACE FUNCTION api.revoke_report_link (
  p_link uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.iss_ok() then
    raise exception 'butuh sesi identity' using errcode = '42501';
  end if;
  update market.report_links rl set revoked_at = now()
   where rl.id = p_link and rl.revoked_at is null
     and exists (select 1 from market.campaigns c where c.id = rl.campaign_id
                 and ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager'));
  if not found then
    raise exception 'link tidak ada atau bukan milik org-mu' using errcode = '42501';
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.save_campaign (
  p_campaign jsonb,
  p_submit   boolean DEFAULT false
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  p jsonb := coalesce(p_campaign, '{}');
  is_admin boolean := ops.has_admin('admin_ops');
  is_brand boolean;
  cols constant text[] := array['title', 'slug', 'type', 'category_id', 'platforms', 'brief', 'required_hashtags',
    'required_mentions', 'required_links', 'sponsored_label', 'min_duration_sec', 'max_duration_sec', 'dos', 'donts', 'example_urls',
    'faq', 'service_mode', 'start_at', 'submit_deadline', 'view_window_days', 'review_mode', 'min_followers', 'min_account_age_days',
    'min_trust_score', 'kyc_required', 'min_views', 'max_clips_per_clipper', 'clipper_quota', 'allow_video_reuse', 'visibility',
    'is_template'];
  c market.campaigns;
  org market.organizations;
  patch jsonb := '{}';
  k text;
  present text[];
  e jsonb;
  pid uuid;
  rt market.reward_types;
  kept uuid[] := '{}';
  kept_assets uuid[] := '{}';
  pool_map jsonb := '{}';
  plat market.platform;
  prefix text;
  aid uuid;
  a_path text;
  a_url text;
  paid_sub numeric;
  send_to_brand boolean;
  inv finance.invoices;
begin
  if jsonb_typeof(p) <> 'object' then
    perform market.fail('invalid:payload', 'p_campaign harus object');
  end if;
  for k in select jsonb_object_keys(p) loop
    if not (k = any (cols) or k in ('id', 'org_id', 'pools', 'rules', 'assets', 'fee_rule')) then
      perform market.fail('invalid:unknown_key', k);
    end if;
  end loop;
  if p ? 'id' then
    select * into c from market.campaigns where id = (p ->> 'id')::uuid for update;
    if c.id is null then
      perform market.fail('not_found:campaign', null, 'P0002');
    end if;
    if p ? 'org_id' and (p ->> 'org_id')::uuid is distinct from c.org_id then
      perform market.fail('invalid:org_id', 'campaign tidak bisa pindah org');
    end if;
  end if;
  select * into org from market.organizations where id = coalesce(c.org_id, (p ->> 'org_id')::uuid);
  if org.id is null then
    perform market.fail('not_found:org', null, 'P0002');
  end if;
  is_brand := ops.is_org_member(org.id, 'brand_owner', 'brand_manager');
  if not (is_brand or is_admin) or (p ? 'fee_rule' and not is_admin) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org atau admin_ops aal2', '42501');
  end if;
  if org.status = 'suspended' then
    perform market.fail('org_suspended', 'org disuspend');
  end if;

  -- Sejak diajukan brief terkunci (trigger campaigns_brief_frozen); di sini hanya FAQ yang diterima.
  if c.id is not null and c.status not in ('draft', 'rejected') then
    if p_submit or exists (select 1 from jsonb_object_keys(p) x where x not in ('id', 'org_id', 'faq')) then
      perform market.fail('campaign_locked', format('campaign %s: yang bisa diubah hanya faq', c.status));
    end if;
    if p ? 'faq' then
      update market.campaigns set faq = p -> 'faq' where id = c.id;
    end if;
    return c.id;
  end if;

  -- Kolom campaign (dinormalisasi)
  for k in select x from jsonb_object_keys(p) x where x = any (cols) loop
    patch := patch || jsonb_build_object(k, p -> k);
  end loop;
  if patch ? 'title' then
    patch := patch || jsonb_build_object('title', btrim(patch ->> 'title'));
  end if;
  if patch ? 'required_hashtags' then
    patch := patch || jsonb_build_object('required_hashtags', market.norm_list(p -> 'required_hashtags', 'hashtag', 'required_hashtags'));
  end if;
  if patch ? 'required_mentions' then
    patch := patch || jsonb_build_object('required_mentions', market.norm_list(p -> 'required_mentions', 'mention', 'required_mentions'));
  end if;
  if patch ? 'required_links' then
    patch := patch || jsonb_build_object('required_links', market.norm_list(p -> 'required_links', 'link', 'required_links'));
  end if;
  if patch ? 'example_urls' then
    patch := patch || jsonb_build_object('example_urls', market.norm_list(p -> 'example_urls', 'link', 'example_urls'));
  end if;
  if patch ? 'dos' then
    patch := patch || jsonb_build_object('dos', market.norm_list(p -> 'dos', 'text', 'dos'));
  end if;
  if patch ? 'donts' then
    patch := patch || jsonb_build_object('donts', market.norm_list(p -> 'donts', 'text', 'donts'));
  end if;
  if patch ? 'slug' then
    patch := patch || jsonb_build_object('slug', lower(btrim(patch ->> 'slug')));
    if (patch ->> 'slug') !~ '^[a-z0-9-]{3,80}$' then
      perform market.fail('invalid:slug', 'slug 3–80 huruf kecil, angka, -');
    end if;
  elsif c.id is null then
    patch := patch || jsonb_build_object('slug',
      left(coalesce(nullif(btrim(regexp_replace(lower(coalesce(patch ->> 'title', '')), '[^a-z0-9]+', '-', 'g'), '-'), ''), 'campaign'), 60)
      || '-' || substr(md5(gen_random_uuid()::text), 1, 6));
  end if;
  if exists (select 1 from market.campaigns x where x.slug = patch ->> 'slug' and x.id is distinct from c.id) then
    perform market.fail('slug_taken', patch ->> 'slug');
  end if;

  select array_agg(x) into present from jsonb_object_keys(patch) x;
  if c.id is null then
    patch := patch || jsonb_build_object('org_id', org.id, 'created_by', uid);
    present := present || array['org_id', 'created_by'];
    execute format('insert into market.campaigns (%1$s) select %1$s from jsonb_populate_record(null::market.campaigns, $1) returning *',
                   (select string_agg(quote_ident(x), ', ') from unnest(present) x))
      using patch into c;
  else
    if c.status = 'rejected' then
      update market.campaigns set status = 'draft' where id = c.id;
    end if;
    if cardinality(present) > 0 then
      execute format('update market.campaigns t set (%1$s) = (select %1$s from jsonb_populate_record(null::market.campaigns, $1)) '
                     'where t.id = $2', (select string_agg(quote_ident(x), ', ') from unnest(present) x))
        using patch, c.id;
    end if;
    select * into c from market.campaigns where id = c.id;
  end if;

  -- Pool & rate rule (§10). rules diganti → hapus dulu supaya pool bisa diganti.
  if p ? 'rules' then
    delete from market.rate_rules where campaign_id = c.id;
  end if;
  if p ? 'pools' then
    if jsonb_typeof(p -> 'pools') <> 'array' then
      perform market.fail('invalid:pools', 'pools harus array');
    end if;
    for e in select jsonb_array_elements(p -> 'pools') loop
      select * into rt from market.reward_types where id = (e ->> 'reward_type_id')::uuid
         and (owner_org_id is null or owner_org_id = org.id);
      if rt.id is null then
        perform market.fail('invalid:reward_type', e ->> 'reward_type_id');
      end if;
      if coalesce(market.jnum(e -> 'total'), 0) <= 0 or coalesce(market.jnum(e -> 'max_per_clip'), 0) <= 0 then
        perform market.fail('invalid:pool', 'total & max_per_clip wajib > 0');
      end if;
      pid := null;
      if e ? 'id' then
        update finance.reward_pools set reward_type_id = rt.id, total = market.jnum(e -> 'total'),
               max_per_clip = market.jnum(e -> 'max_per_clip')
         where id = (e ->> 'id')::uuid and campaign_id = c.id
        returning id into pid;
        if pid is null then
          perform market.fail('invalid:pool_id', e ->> 'id');
        end if;
      else
        insert into finance.reward_pools (campaign_id, reward_type_id, total, max_per_clip)
        values (c.id, rt.id, market.jnum(e -> 'total'), market.jnum(e -> 'max_per_clip'))
        returning id into pid;
      end if;
      kept := kept || pid;
      if e ? 'key' then
        pool_map := pool_map || jsonb_build_object(e ->> 'key', pid);
      end if;
    end loop;
    begin
      delete from finance.reward_pools where campaign_id = c.id and not (id = any (kept));
    exception when foreign_key_violation then
      perform market.fail('invalid:pool_in_use', 'pool masih dipakai rate rule; kirim rules juga');
    end;
  end if;
  select pool_map || coalesce(jsonb_object_agg(pl.id::text, pl.id), '{}') into pool_map
    from finance.reward_pools pl where pl.campaign_id = c.id;
  if p ? 'rules' then
    if jsonb_typeof(p -> 'rules') <> 'array' then
      perform market.fail('invalid:rules', 'rules harus array');
    end if;
    for e in select jsonb_array_elements(p -> 'rules') loop
      perform market.check_rule_params(e ->> 'kind', e -> 'params');
      plat := nullif(e ->> 'platform', '')::market.platform;
      if plat is not null and not (plat = any (c.platforms)) then
        perform market.fail('invalid:rule_platform', plat::text);
      end if;
      pid := coalesce((pool_map ->> (e ->> 'pool'))::uuid, (pool_map ->> (e ->> 'pool_id'))::uuid);
      if pid is null and e ? 'reward_type_id' then
        select min(pl.id::text)::uuid into pid from finance.reward_pools pl
         where pl.campaign_id = c.id and pl.reward_type_id = (e ->> 'reward_type_id')::uuid
        having count(*) = 1;
      end if;
      if pid is null then
        perform market.fail('invalid:rule_pool', 'rule harus menunjuk satu pool campaign ini');
      end if;
      if e ? 'reward_type_id' and not exists (select 1 from finance.reward_pools pl where pl.id = pid
                                              and pl.reward_type_id = (e ->> 'reward_type_id')::uuid) then
        perform market.fail('invalid:rule_reward_type', 'reward type rule ≠ reward type pool');
      end if;
      insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, platform, params)
      select c.id, e ->> 'kind', pl.reward_type_id, pl.id, plat, e -> 'params' from finance.reward_pools pl where pl.id = pid;
    end loop;
  end if;

  -- Aset (E-10): file wajib di folder {org}/{campaign}/ (internal/ = berkas brief mentah, hanya anggota org + admin).
  if p ? 'assets' then
    if jsonb_typeof(p -> 'assets') <> 'array' then
      perform market.fail('invalid:assets', 'assets harus array');
    end if;
    prefix := org.id::text || '/' || c.id::text || '/';
    for e in select jsonb_array_elements(p -> 'assets') loop
      a_path := nullif(btrim(e ->> 'storage_path'), '');
      a_url := (market.norm_list(case when e ? 'url' then jsonb_build_array(e -> 'url') end, 'link', 'asset_url'))[1];
      if a_path is not null and left(a_path, length(prefix)) <> prefix then
        perform market.fail('invalid:asset_path', format('file harus di folder %s', prefix));
      end if;
      select x.id into aid from market.campaign_assets x
       where x.campaign_id = c.id and (x.storage_path = a_path or x.url = a_url) limit 1;
      if aid is null then
        insert into market.campaign_assets (campaign_id, kind, storage_path, url, size_bytes, audience)
        values (c.id, e ->> 'kind', a_path, a_url, market.jnum(e -> 'size_bytes')::bigint,
                coalesce(e ->> 'audience', case when split_part(a_path, '/', 3) = 'internal' then 'internal' else 'clipper' end))
        returning id into aid;
      end if;
      kept_assets := kept_assets || aid;
    end loop;
    delete from market.campaign_assets where campaign_id = c.id and not (id = any (kept_assets));
  end if;

  -- Override fee per campaign (F-A03, admin).
  if p ? 'fee_rule' then
    update market.campaigns set fee_rule_id = case when jsonb_typeof(p -> 'fee_rule') = 'null' then null
      else finance.create_fee_rule('campaign', p -> 'fee_rule', finance.effective_fee_rule(org.id, null), uid) end
     where id = c.id;
  end if;

  -- Invoice campaign yang sudah lunas mengunci budget (pool bisa ditambah lewat top-up saja).
  select sum(i.subtotal) into paid_sub from finance.invoices i
   where i.campaign_id = c.id and i.kind in ('campaign', 'topup') and i.status = 'paid';
  if paid_sub is not null and p ? 'pools' and round(finance.campaign_budget_idr(c.id), 2) <> paid_sub then
    perform market.fail('pools_locked_after_payment', 'budget sudah dibayar; ubah lewat top-up');
  end if;

  if not p_submit then
    return c.id;
  end if;

  select * into c from market.campaigns where id = c.id;
  if c.is_template then
    perform market.fail('invalid:template', 'template tidak bisa diajukan; duplikat dulu');
  end if;
  if c.start_at is null or c.submit_deadline is null then
    perform market.fail('invalid:schedule', 'start_at & submit_deadline wajib');
  end if;
  if c.submit_deadline <= now() then
    perform market.fail('invalid:submit_deadline', 'deadline submit sudah lewat');
  end if;
  if not exists (select 1 from finance.reward_pools pl where pl.campaign_id = c.id) then
    perform market.fail('invalid:pools', 'minimal satu pool');
  end if;
  if exists (select 1 from finance.reward_pools pl where pl.campaign_id = c.id
             and not exists (select 1 from market.rate_rules r where r.pool_id = pl.id)) then
    perform market.fail('invalid:rules', 'tiap pool butuh minimal satu rate rule');
  end if;

  send_to_brand := is_admin and not is_brand and c.service_mode = 'managed';
  if send_to_brand then
    -- J-A7: tim selesai menyusun → invoice paket managed (sekali) + kabari brand; brand yang mengajukan.
    if not exists (select 1 from finance.invoices i where i.campaign_id = c.id and i.kind = 'managed_service' and i.status <> 'void') then
      perform finance.issue_invoice(org.id, c.id, 'managed_service', 0,
        coalesce((select (s.value #>> '{}')::numeric from ops.settings s where s.key = 'public.billing.managed_service_idr'), 2500000));
    end if;
    perform market.notify_org(org.id, array['brand_owner', 'brand_manager']::market.org_role[], 'managed.draft_ready',
                              jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title));
    return c.id;
  end if;

  if org.status <> 'verified' then
    perform market.fail('org_not_verified', 'org belum diverifikasi admin');
  end if;
  update market.campaigns set status = 'in_review' where id = c.id;
  if paid_sub is null then
    update finance.invoices set status = 'void' where campaign_id = c.id and kind = 'campaign' and status = 'issued';
    inv := finance.issue_invoice(org.id, c.id, 'campaign', finance.campaign_budget_idr(c.id));
  end if;
  return c.id;
end $function$;

CREATE OR REPLACE FUNCTION api.save_reward_type (
  p jsonb
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  cur market.reward_types;
  org uuid;
  rid uuid;
  sec uuid;
  k text;
  allowed constant text[] := array['id', 'owner_org_id', 'code', 'name', 'kind', 'unit_label', 'idr_value_per_unit', 'decimals',
                                   'fulfillment', 'recipient_schema', 'stock', 'webhook_url', 'webhook_secret',
                                   'fulfillment_margin_pct'];
begin
  if jsonb_typeof(p) is distinct from 'object' then
    perform market.fail('invalid:payload', 'p harus object');
  end if;
  for k in select jsonb_object_keys(p) loop
    if not (k = any (allowed)) then
      perform market.fail('invalid:unknown_key', k);
    end if;
  end loop;
  if p ? 'id' then
    select * into cur from market.reward_types where id = (p ->> 'id')::uuid for update;
    if cur.id is null then
      perform market.fail('not_found:reward_type', null, 'P0002');
    end if;
    org := cur.owner_org_id;
  else
    org := (p ->> 'owner_org_id')::uuid;
  end if;
  if org is null then
    if not ops.has_admin('admin_super') then
      perform market.fail('auth:forbidden', 'reward type global hanya admin_super', '42501');
    end if;
  elsif not (ops.is_org_member(org, 'brand_owner', 'brand_manager') or ops.has_admin('admin_ops')) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  if p ? 'fulfillment_margin_pct' and not ops.has_admin('admin_super') then
    perform market.fail('auth:forbidden', 'margin fulfillment diatur admin_super', '42501');
  end if;
  if cur.id is not null and exists (select 1 from finance.reward_pools pl where pl.reward_type_id = cur.id)
     and ((p ? 'code' and upper(p ->> 'code') <> cur.code) or (p ? 'kind' and p ->> 'kind' <> cur.kind)
          or (p ? 'idr_value_per_unit' and market.jnum(p -> 'idr_value_per_unit') <> cur.idr_value_per_unit)
          or (p ? 'decimals' and (p ->> 'decimals')::smallint <> cur.decimals)
          or (p ? 'fulfillment' and p ->> 'fulfillment' <> cur.fulfillment)) then
    perform market.fail('reward_type_in_use', 'sudah dipakai pool; buat reward type baru');
  end if;
  if p ? 'recipient_schema' and jsonb_typeof(p -> 'recipient_schema') <> 'array' then
    perform market.fail('invalid:recipient_schema', 'array field penerima [{key, label, pii}]');
  end if;

  -- Secret webhook (HMAC) ke Vault core lebih dulu (constraint reward_types_webhook_complete); tabel hanya memegang ref.
  rid := coalesce(cur.id, gen_random_uuid());
  sec := cur.webhook_secret_ref;
  if nullif(p ->> 'webhook_secret', '') is not null then
    if sec is null then
      sec := vault.create_secret(p ->> 'webhook_secret', 'reward_webhook:' || rid::text, 'secret webhook reward type');
    else
      perform vault.update_secret(sec, p ->> 'webhook_secret');
    end if;
  end if;

  if cur.id is null then
    insert into market.reward_types (id, owner_org_id, code, name, kind, unit_label, idr_value_per_unit, decimals, fulfillment,
                                     recipient_schema, stock, webhook_url, webhook_secret_ref, fulfillment_margin_pct)
    values (rid, org, upper(btrim(p ->> 'code')), btrim(p ->> 'name'), p ->> 'kind', btrim(p ->> 'unit_label'),
            market.jnum(p -> 'idr_value_per_unit'), coalesce((p ->> 'decimals')::smallint, 0), p ->> 'fulfillment',
            coalesce(p -> 'recipient_schema', '[]'), market.jnum(p -> 'stock'), nullif(btrim(p ->> 'webhook_url'), ''), sec,
            coalesce(market.jnum(p -> 'fulfillment_margin_pct'), 0));
  else
    update market.reward_types set
      code = case when p ? 'code' then upper(btrim(p ->> 'code')) else code end,
      name = case when p ? 'name' then btrim(p ->> 'name') else name end,
      kind = case when p ? 'kind' then p ->> 'kind' else kind end,
      unit_label = case when p ? 'unit_label' then btrim(p ->> 'unit_label') else unit_label end,
      idr_value_per_unit = case when p ? 'idr_value_per_unit' then market.jnum(p -> 'idr_value_per_unit') else idr_value_per_unit end,
      decimals = case when p ? 'decimals' then (p ->> 'decimals')::smallint else decimals end,
      fulfillment = case when p ? 'fulfillment' then p ->> 'fulfillment' else fulfillment end,
      recipient_schema = case when p ? 'recipient_schema' then p -> 'recipient_schema' else recipient_schema end,
      stock = case when p ? 'stock' then market.jnum(p -> 'stock') else stock end,
      webhook_url = case when p ? 'webhook_url' then nullif(btrim(p ->> 'webhook_url'), '') else webhook_url end,
      webhook_secret_ref = sec,
      fulfillment_margin_pct = case when p ? 'fulfillment_margin_pct' then market.jnum(p -> 'fulfillment_margin_pct')
                                    else fulfillment_margin_pct end
     where id = rid;
  end if;
  return rid;
end $function$;

CREATE OR REPLACE FUNCTION api.send_broadcast (
  p_title        text,
  p_body         text,
  p_segment      jsonb                    DEFAULT '{}'::jsonb,
  p_channels     text[]                   DEFAULT '{in_app}'::text[],
  p_scheduled_at timestamp with time zone DEFAULT NULL::timestamp WITH time zone
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  seg jsonb := coalesce(p_segment, '{}');
  k text;
  bid uuid;
begin
  if not ops.has_admin('admin_ops') then
    perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
  end if;
  if jsonb_typeof(seg) <> 'object' then
    perform market.fail('invalid:segment', 'segmen harus object');
  end if;
  for k in select jsonb_object_keys(seg) loop
    if k not in ('platforms', 'min_trust_score', 'max_trust_score', 'kyc', 'active_days') then
      perform market.fail('invalid:segment', k);
    end if;
  end loop;
  if seg ? 'platforms' and (jsonb_typeof(seg -> 'platforms') <> 'array'
     or exists (select 1 from jsonb_array_elements_text(seg -> 'platforms') x
                where x not in (select unnest(enum_range(null::market.platform))::text))) then
    perform market.fail('invalid:segment', 'platforms');
  end if;
  if seg ? 'kyc' and seg ->> 'kyc' not in ('approved', 'not_approved') then
    perform market.fail('invalid:segment', 'kyc');
  end if;
  if (seg ? 'min_trust_score' and market.jnum(seg -> 'min_trust_score') is null)
     or (seg ? 'max_trust_score' and market.jnum(seg -> 'max_trust_score') is null)
     or (seg ? 'active_days' and coalesce(market.jnum(seg -> 'active_days'), 0) <= 0) then
    perform market.fail('invalid:segment', 'angka segmen');
  end if;
  insert into ops.broadcasts (title, body, segment, channels, created_by, scheduled_at)
  values (btrim(p_title), btrim(p_body), seg, coalesce(p_channels, '{in_app}'), uid, coalesce(p_scheduled_at, now()))
  returning id into bid;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'broadcast.create', 'broadcast:' || bid, null,
          jsonb_build_object('title', btrim(p_title), 'segment', seg, 'channels', p_channels, 'scheduled_at', p_scheduled_at));
  return bid;
end $function$;

CREATE OR REPLACE FUNCTION api.store_social_token (
  p_account_id uuid,
  p_token      text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  sid uuid;
begin
  select a.token_ref into sid from tracking.social_accounts a where a.id = p_account_id for update;
  if not found then
    raise exception 'akun sosmed % tidak ada', p_account_id using errcode = 'P0002';
  end if;
  if sid is null then
    sid := vault.create_secret(p_token, 'social:' || p_account_id::text, 'token OAuth sosmed');
    update tracking.social_accounts set token_ref = sid where id = p_account_id;
  else
    perform vault.update_secret(sid, p_token);
  end if;
  update tracking.social_accounts set status = 'verified', verified_at = now()
   where id = p_account_id and status in ('token_expired', 'verified');
  return sid;
end $function$;

CREATE OR REPLACE FUNCTION api.update_config (
  p_key   text,
  p_value jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  v jsonb := coalesce(p_value, 'null');
  old jsonb;
  new jsonb;
  act text;
  tgt text;
  rid uuid;
  cid uuid;
begin
  if p_key in ('categories.upsert', 'campaign.pin', 'fee_rules.org', 'fee_rules.campaign', 'public.home.banners') then
    if not ops.has_admin('admin_ops') then
      perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
    end if;
  elsif not ops.has_admin('admin_super') then
    perform market.fail('auth:forbidden', 'butuh admin_super aal2', '42501');
  end if;

  if p_key = 'categories.upsert' then
    if coalesce(v ->> 'id', '') !~ '^[a-z0-9-]{2,30}$' or nullif(btrim(v ->> 'name_id'), '') is null
       or nullif(btrim(v ->> 'name_en'), '') is null then
      perform market.fail('invalid:category', 'id (a-z0-9-), name_id, name_en wajib');
    end if;
    select to_jsonb(x) into old from market.categories x where x.id = v ->> 'id';
    insert into market.categories as k (id, name_id, name_en, sort, active)
    values (v ->> 'id', btrim(v ->> 'name_id'), btrim(v ->> 'name_en'), coalesce((v ->> 'sort')::smallint, 0),
            coalesce((v ->> 'active')::boolean, true))
    on conflict (id) do update set name_id = excluded.name_id, name_en = excluded.name_en,
      sort = case when v ? 'sort' then excluded.sort else k.sort end,
      active = case when v ? 'active' then excluded.active else k.active end;
    select to_jsonb(x) into new from market.categories x where x.id = v ->> 'id';
    act := 'config.category'; tgt := 'category:' || (v ->> 'id');

  elsif p_key = 'campaign.pin' then
    cid := (v ->> 'campaign_id')::uuid;
    if (v ->> 'rank')::int < 1 then
      perform market.fail('invalid:rank', 'rank ≥ 1');
    end if;
    select jsonb_build_object('pinned_rank', c.pinned_rank, 'pinned_until', c.pinned_until) into old
      from market.campaigns c where c.id = cid for update;
    if old is null then
      perform market.fail('not_found:campaign', null, 'P0002');
    end if;
    update market.campaigns set pinned_rank = (v ->> 'rank')::smallint, pinned_until = (v ->> 'until')::timestamptz where id = cid;
    new := jsonb_build_object('pinned_rank', v -> 'rank', 'pinned_until', v -> 'until');
    act := 'config.pin'; tgt := 'campaign:' || cid;

  elsif p_key = 'fee_rules.global' then
    select to_jsonb(f), f.id into old, rid from finance.fee_rules f where f.scope = 'global' for update;
    if rid is null then
      perform market.fail('config:fee_rule_missing', 'fee rule global belum ada (seed)');
    end if;
    update finance.fee_rules set
      mgmt_fee_pct = coalesce(market.jnum(v -> 'mgmt_fee_pct'), mgmt_fee_pct),
      admin_fee_pct = coalesce(market.jnum(v -> 'admin_fee_pct'), admin_fee_pct),
      clipper_fee_pct = coalesce(market.jnum(v -> 'clipper_fee_pct'), clipper_fee_pct),
      instant_withdraw_fee = case when v ? 'instant_withdraw_fee' then market.jnum(v -> 'instant_withdraw_fee') else instant_withdraw_fee end
     where id = rid;
    select to_jsonb(f) into new from finance.fee_rules f where f.id = rid;
    act := 'config.fee_rule'; tgt := 'fee_rule:global';

  elsif p_key in ('fee_rules.org', 'fee_rules.campaign') then
    if p_key = 'fee_rules.org' then
      cid := (v ->> 'org_id')::uuid;
      select to_jsonb(f) into old from market.organizations o left join finance.fee_rules f on f.id = o.fee_rule_id where o.id = cid;
      if not exists (select 1 from market.organizations o where o.id = cid) then
        perform market.fail('not_found:org', null, 'P0002');
      end if;
    else
      cid := (v ->> 'campaign_id')::uuid;
      if not exists (select 1 from market.campaigns c where c.id = cid) then
        perform market.fail('not_found:campaign', null, 'P0002');
      end if;
      select to_jsonb(f) into old from market.campaigns c left join finance.fee_rules f on f.id = c.fee_rule_id where c.id = cid;
    end if;
    if not coalesce((v ->> 'clear')::boolean, false) then
      rid := finance.create_fee_rule(case p_key when 'fee_rules.org' then 'org' else 'campaign' end,
                                     v - 'org_id' - 'campaign_id',
                                     case p_key when 'fee_rules.org' then finance.effective_fee_rule(null, null)
                                                else finance.effective_fee_rule((select c.org_id from market.campaigns c where c.id = cid), null) end,
                                     uid);
    end if;
    if p_key = 'fee_rules.org' then
      update market.organizations set fee_rule_id = rid where id = cid;
    else
      update market.campaigns set fee_rule_id = rid where id = cid;
    end if;
    select to_jsonb(f) into new from finance.fee_rules f where f.id = rid;
    act := 'config.fee_rule'; tgt := case p_key when 'fee_rules.org' then 'org:' else 'campaign:' end || cid;

  else
    if p_key like 'auth.%' then
      perform market.fail('config_key_locked', 'issuer identity diubah lewat migration Fase 0, bukan dari admin');
    end if;
    select s.value into old from ops.settings s where s.key = p_key for update;
    if old is null then
      perform market.fail('invalid:config_key', coalesce(p_key, 'null'));
    end if;
    if jsonb_typeof(v) <> jsonb_typeof(old) then
      perform market.fail('invalid:value_type', format('%s harus %s', p_key, jsonb_typeof(old)));
    end if;
    update ops.settings set value = v, updated_by = uid, updated_at = now() where key = p_key;
    new := v;
    act := 'config.update'; tgt := 'settings:' || p_key;
  end if;

  insert into ops.audit_logs (actor_id, action, target, before, after) values (uid, act, tgt, old, new);
end $function$;

CREATE OR REPLACE FUNCTION api.upload_reward_codes (
  p_reward_type uuid,
  p_codes       text[]
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  rt market.reward_types;
  n int;
begin
  select * into rt from market.reward_types where id = p_reward_type;
  if rt.id is null then
    perform market.fail('not_found:reward_type', null, 'P0002');
  end if;
  if rt.owner_org_id is null or not ops.is_org_member(rt.owner_org_id, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager pemilik reward type', '42501');
  end if;
  if rt.fulfillment <> 'code_pool' then
    perform market.fail('invalid:fulfillment', 'reward type ini bukan pool kode');
  end if;
  if coalesce(cardinality(p_codes), 0) > 10000 then
    perform market.fail('invalid:codes', 'maks 10.000 kode per unggahan');
  end if;
  insert into finance.reward_codes (reward_type_id, code, uploaded_by)
  select rt.id, x.code, uid from (select distinct btrim(u) as code from unnest(p_codes) u where btrim(u) <> '') x
  on conflict (reward_type_id, code) do nothing;
  get diagnostics n = row_count;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_account_status (
  p_account uuid,
  p_status  text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  a tracking.social_accounts;
  new_status text := case p_status when 'expired' then 'token_expired' when 'revoked' then 'revoked' when 'verified' then 'verified' end;
begin
  if new_status is null then
    raise exception 'invalid:status' using errcode = 'P0001';
  end if;
  select * into a from tracking.social_accounts x where x.id = p_account for update;
  if not found then
    raise exception 'not_found:social_account' using errcode = 'P0002';
  end if;
  if a.status = 'disconnected' then
    return;
  end if;
  if new_status = 'verified' then
    update tracking.social_accounts set status = 'verified', verified_at = now() where id = a.id;
    update tracking.submissions set next_poll_at = now()
     where social_account_id = a.id and status in ('tracking', 'flagged') and next_poll_at is null;
  else
    update tracking.social_accounts set status = new_status where id = a.id and status <> new_status;
    if a.status = 'verified' then
      perform ops.enqueue_notification(a.user_id, 'social.token_expired',
                                       jsonb_build_object('account_id', a.id, 'platform', a.platform, 'handle', a.handle));
    end if;
    update tracking.submissions set next_poll_at = null where social_account_id = a.id and status in ('tracking', 'flagged');
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_account_token (
  p_account uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  a tracking.social_accounts;
begin
  select * into a from tracking.social_accounts x where x.id = p_account;
  if not found then
    raise exception 'not_found:social_account' using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', a.id, 'user_id', a.user_id, 'platform', a.platform, 'external_id', a.external_id, 'handle', a.handle,
                            'status', a.status,
                            'token', (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.id = a.token_ref));
end $function$;

CREATE OR REPLACE FUNCTION api.worker_accounts_to_refresh (
  p_within interval
)
  RETURNS TABLE (
    account_id uuid,
    platform   market.platform,
    token      text
  )
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r record;
  exp timestamptz;
begin
  for r in select a.id, a.platform as pf, ds.decrypted_secret as tok
             from tracking.social_accounts a join vault.decrypted_secrets ds on ds.id = a.token_ref
            where a.status in ('verified', 'token_expired') order by a.id loop
    exp := null;
    if ltrim(r.tok) like '{%' then
      begin
        exp := (r.tok::jsonb ->> 'expires_at')::timestamptz;
      exception when others then
        exp := null;
      end;
    end if;
    if exp < now() + p_within then
      account_id := r.id;
      platform := r.pf;
      token := r.tok;
      return next;
    end if;
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_ack (
  p_queue  text,
  p_msg_id bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if p_queue is null or p_queue not in ('tracking', 'email') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  perform pgmq.delete(p_queue, p_msg_id);
end $function$;

CREATE OR REPLACE FUNCTION api.worker_assign_code (
  p_fulfillment uuid
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  f finance.fulfillments;
  cid uuid;
  code text;
begin
  select * into f from finance.fulfillments x where x.id = p_fulfillment for update;
  if not found then
    raise exception 'not_found:fulfillment' using errcode = 'P0002';
  end if;
  if (select rt.fulfillment from market.reward_types rt where rt.id = f.reward_type_id) <> 'code_pool' then
    raise exception 'invalid:fulfillment_kind' using errcode = 'P0001';
  end if;
  select rc.code into code from finance.reward_codes rc where rc.fulfillment_id = f.id;
  if code is not null then
    return code;
  end if;
  if f.status <> 'requested' then
    return null;
  end if;
  select rc.id, rc.code into cid, code from finance.reward_codes rc
   where rc.reward_type_id = f.reward_type_id and rc.fulfillment_id is null
   order by rc.created_at, rc.id limit 1 for update skip locked;
  if cid is null then
    update finance.fulfillments set status = 'on_hold', last_error = 'code_pool_empty' where id = f.id;
    perform ops.raise_alert('fulfillment.stuck', 'warning',
                            jsonb_build_object('fulfillment_id', f.id, 'reward_type_id', f.reward_type_id, 'reason', 'code_pool_empty'));
    return null;
  end if;
  update finance.reward_codes set fulfillment_id = f.id, assigned_at = now() where id = cid;
  return code;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_create_submission (
  p_user         uuid,
  p_claim        uuid,
  p_account      uuid,
  p_post_id      text,
  p_url          text,
  p_posted_at    timestamp with time zone,
  p_caption      text,
  p_duration_sec integer
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  cl market.claims;
  c market.campaigns;
  a tracking.social_accounts;
  missing text[];
  sid uuid;
  st tracking.submission_status;
begin
  if not exists (select 1 from market.profiles pr where pr.id = p_user and pr.status = 'active') then
    raise exception 'profile_inactive' using errcode = 'P0001';
  end if;
  select * into cl from market.claims k where k.id = p_claim for update;
  if not found then
    raise exception 'claim_not_open' using errcode = 'P0001';
  end if;
  if cl.user_id <> p_user then
    raise exception 'not_your_claim' using errcode = 'P0001';
  end if;
  if cl.status <> 'open' or cl.expires_at <= now() then
    raise exception 'claim_not_open' using errcode = 'P0001';
  end if;
  select * into c from market.campaigns k where k.id = cl.campaign_id;
  if c.status <> 'live' or c.submit_deadline <= now() then
    raise exception 'campaign_closed' using errcode = 'P0001';
  end if;
  select * into a from tracking.social_accounts x where x.id = p_account;
  if not found or a.user_id <> p_user then
    raise exception 'account_not_yours' using errcode = 'P0001';
  end if;
  if a.status <> 'verified' then
    raise exception 'account_inactive' using errcode = 'P0001';
  end if;
  if not (a.platform = any (c.platforms)) then
    raise exception 'platform_not_allowed' using errcode = 'P0001';
  end if;
  if p_posted_at is null or p_posted_at < cl.created_at then
    raise exception 'posted_before_claim' using errcode = 'P0001';
  end if;
  missing := api.missing_brief_tags(c.id, p_caption);
  if cardinality(missing) > 0 then
    raise exception 'missing_tags:%', array_to_string(missing, ',') using errcode = 'P0001';
  end if;
  if p_duration_sec < c.min_duration_sec or p_duration_sec > c.max_duration_sec then
    raise exception 'duration_out_of_range' using errcode = 'P0001';
  end if;
  if exists (select 1 from tracking.submissions t where t.campaign_id = c.id and t.platform = a.platform and t.post_id = p_post_id) then
    raise exception 'already_submitted' using errcode = 'P0001';
  end if;
  if not c.allow_video_reuse and exists (select 1 from tracking.submissions t
                                         where t.platform = a.platform and t.post_id = p_post_id and t.campaign_id <> c.id) then
    raise exception 'reused_video' using errcode = 'P0001';
  end if;
  if p_post_id is null or btrim(p_post_id) = '' or p_url is null or p_url !~ '^https://' then
    raise exception 'invalid:url' using errcode = 'P0001';
  end if;

  begin
    insert into tracking.submissions (claim_id, user_id, campaign_id, social_account_id, platform, post_id, url, posted_at)
    values (cl.id, p_user, c.id, a.id, a.platform, p_post_id, p_url, p_posted_at) returning id into sid;
  exception when unique_violation then
    raise exception 'already_submitted' using errcode = 'P0001';
  end;
  st := case when c.review_mode in ('manual', 'brand')
                  or (p_duration_sec is null and (c.min_duration_sec is not null or c.max_duration_sec is not null))
             then 'in_review' else 'tracking' end;
  update tracking.submissions set status = st, next_poll_at = case when st = 'tracking' then now() end where id = sid;
  update market.claims set status = 'submitted' where id = cl.id;
  if c.review_mode = 'brand' and st = 'in_review' then
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'submission.pending_review',
                              market.campaign_ref(c.id) || jsonb_build_object('submission_id', sid));
  end if;
  return jsonb_build_object('submission_id', sid, 'status', st);
end $function$;

CREATE OR REPLACE FUNCTION api.worker_defer (
  p_submission uuid,
  p_until      timestamp with time zone
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if p_until is null then
    raise exception 'invalid:until' using errcode = 'P0001';
  end if;
  update tracking.submissions t
     set next_poll_at = least(p_until, t.posted_at + make_interval(days => (select c.view_window_days from market.campaigns c
                                                                            where c.id = t.campaign_id)))
   where t.id = p_submission and t.status in ('tracking', 'flagged');
  if not found and not exists (select 1 from tracking.submissions t where t.id = p_submission) then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_dequeue (
  p_queue      text,
  p_qty        integer DEFAULT 20,
  p_vt_seconds integer DEFAULT 300
)
  RETURNS TABLE (
    msg_id  bigint,
    message jsonb
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if p_queue is null or p_queue not in ('tracking', 'email') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  return query select q.msg_id, q.message
                 from pgmq.read(p_queue, greatest(coalesce(p_vt_seconds, 300), 1), least(greatest(coalesce(p_qty, 20), 1), 100)) q;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_fulfillment_result (
  p_fulfillment uuid,
  p_ok          boolean,
  p_ref         text,
  p_error       text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  f finance.fulfillments;
begin
  select * into f from finance.fulfillments x where x.id = p_fulfillment for update;
  if not found then
    raise exception 'not_found:fulfillment' using errcode = 'P0002';
  end if;
  if f.status = 'delivered' then
    return;
  end if;
  if p_ok then
    if f.status in ('requested', 'on_hold') then
      update finance.fulfillments set status = 'processing' where id = f.id;
    end if;
    update finance.fulfillments set status = 'delivered', delivered_ref = p_ref, delivered_at = now(), last_error = null,
           next_retry_at = null
     where id = f.id;
    perform ops.enqueue_notification(f.user_id, 'fulfillment.delivered', finance.amount_ref(f.reward_type_id, f.amount)
                                     || jsonb_build_object('fulfillment_id', f.id, 'reward_type_id', f.reward_type_id,
                                                           'reward_name', (select rt.name from market.reward_types rt where rt.id = f.reward_type_id)));
  else
    update finance.fulfillments set attempts = attempts + 1, last_error = left(p_error, 500), next_retry_at = now() + interval '5 minutes'
     where id = f.id;
    if f.attempts + 1 >= 12 and f.status = 'requested' then
      update finance.fulfillments set status = 'on_hold', next_retry_at = null where id = f.id;
      perform ops.raise_alert('fulfillment.stuck', 'warning',
                              jsonb_build_object('fulfillment_id', f.id, 'attempts', f.attempts + 1, 'error', left(p_error, 500)));
    end if;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_fulfillments_due (
  p_limit integer
)
  RETURNS TABLE (
    id             uuid,
    user_id        uuid,
    reward_type_id uuid,
    amount         numeric,
    recipient      jsonb,
    fulfillment    text,
    webhook_url    text,
    webhook_secret text,
    attempts       smallint
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
#variable_conflict use_column
begin
  return query
  with due as (
    select f.id as fid from finance.fulfillments f join market.reward_types rt on rt.id = f.reward_type_id
     where f.status = 'requested' and rt.fulfillment in ('code_pool', 'webhook')
       and (f.next_retry_at is null or f.next_retry_at <= now())
     order by coalesce(f.next_retry_at, f.created_at), f.id
     limit greatest(coalesce(p_limit, 20), 1)
     for update of f skip locked),
  upd as (
    update finance.fulfillments f set next_retry_at = now() + interval '5 minutes' from due where f.id = due.fid
    returning f.id as fid, f.user_id as uid, f.reward_type_id as rtid, f.amount as amt, f.recipient as rcp, f.attempts as att)
  select upd.fid, upd.uid, upd.rtid, upd.amt::numeric, upd.rcp, rt.fulfillment, rt.webhook_url,
         (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.id = rt.webhook_secret_ref), upd.att
    from upd join market.reward_types rt on rt.id = upd.rtid;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_notification (
  p_id bigint
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  n ops.notifications;
begin
  select * into n from ops.notifications x where x.id = p_id;
  if not found then
    return null;
  end if;
  return jsonb_build_object('user_id', n.user_id, 'event', n.event, 'payload', n.payload,
                            'promo', n.event in ('campaign.new', 'broadcast.sent'));
end $function$;

CREATE OR REPLACE FUNCTION api.worker_post_gone (
  p_submission uuid,
  p_reason     text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  if s.status not in ('tracking', 'flagged') then
    return;
  end if;
  perform trust.raise_flag('submission', s.id, 'FR-06', 100, jsonb_build_object('post_gone', true, 'reason', p_reason), 'actioned');
  update tracking.submissions set status = 'forfeited', next_poll_at = null where id = s.id;
  perform finance.reverse_earning(s.id, 'post_gone');
  perform ops.enqueue_notification(s.user_id, 'submission.forfeited', market.campaign_ref(s.campaign_id)
                                   || jsonb_build_object('submission_id', s.id, 'reason', coalesce(p_reason, 'post_gone')));
end $function$;

CREATE OR REPLACE FUNCTION api.worker_record_snapshot (
  p_submission uuid,
  p_views      bigint,
  p_likes      bigint,
  p_comments   bigint,
  p_shares     bigint,
  p_caption    text,
  p_raw        jsonb,
  p_extra      jsonb  DEFAULT '{}'::jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  c market.campaigns;
  a tracking.social_accounts;
  fin boolean;
  sid bigint;
  taken timestamptz;
  hold boolean := false;
  raised boolean := false;
  missing text[];
  med numeric;
  peers int;
  reach numeric;
  watch numeric;
  skip numeric;
  id_views numeric;
  all_views numeric;
  window_end timestamptz;
  every_h numeric;
  nxt timestamptz;
  st tracking.submission_status;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  if s.status not in ('tracking', 'flagged') then
    return jsonb_build_object('snapshot_id', null, 'flagged', s.status = 'flagged', 'next_poll_at', null,
                              'locked', s.status in ('locked', 'settled'));
  end if;
  if p_views is null or p_views < 0 then
    raise exception 'invalid:views' using errcode = 'P0001';
  end if;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  select * into a from tracking.social_accounts x where x.id = s.social_account_id;
  window_end := s.posted_at + make_interval(days => c.view_window_days);
  fin := tracking.final_due(s.id);
  insert into tracking.view_snapshots (submission_id, taken_at, views, likes, comments, shares, is_final, raw)
  values (s.id, clock_timestamp(), p_views, p_likes, p_comments, p_shares, fin,
          nullif(case when jsonb_typeof(p_raw) = 'object' then p_raw when p_raw is null then '{}' else jsonb_build_object('response', p_raw) end
                 || case when jsonb_typeof(p_extra) = 'object' and p_extra <> '{}' then jsonb_build_object('extra', p_extra) else '{}' end,
                 '{}'))
  returning id, taken_at into sid, taken;

  if p_caption is not null then
    missing := api.missing_brief_tags(c.id, p_caption);
    if cardinality(missing) > 0 then
      raised := trust.raise_flag('submission', s.id, 'FR-06', 80, jsonb_build_object('missing', missing, 'snapshot_id', sid))
                is not null or raised;
      hold := true;
    end if;
  end if;
  if p_likes is not null and p_views >= greatest(c.min_views, 1000)
     and (p_likes + coalesce(p_comments, 0) + coalesce(p_shares, 0))::numeric / p_views
         < (ops.cfg('trust.fraud.like_rate_min', '0.005'))::numeric then
    raised := trust.raise_flag('submission', s.id, 'FR-01', 50,
                               jsonb_build_object('views', p_views, 'likes', p_likes, 'comments', p_comments, 'shares', p_shares,
                                                  'snapshot_id', sid)) is not null or raised;
  end if;
  select percentile_cont(0.5) within group (order by o.counted_views), count(*) into med, peers
    from tracking.submissions o
   where o.social_account_id = s.social_account_id and o.id <> s.id and o.status in ('tracking', 'flagged', 'locked', 'settled');
  if peers >= 3 and med > 0 and p_views > med * (ops.cfg('trust.fraud.spike_multiplier', '10'))::numeric then
    raised := trust.raise_flag('submission', s.id, 'FR-02', 70, jsonb_build_object('views', p_views, 'median', med, 'peers', peers))
              is not null or raised;
    hold := true;
  end if;
  if a.platform_created_at > now() - make_interval(days => (ops.cfg('trust.fraud.new_account_days', '14'))::int)
     and p_views >= (ops.cfg('trust.fraud.new_account_views', '100000'))::bigint then
    raised := trust.raise_flag('submission', s.id, 'FR-03', 60,
                               jsonb_build_object('views', p_views, 'account_created_at', a.platform_created_at,
                                                  'followers', a.followers)) is not null or raised;
  end if;
  reach := case when jsonb_typeof(p_extra -> 'reach') = 'number' then (p_extra ->> 'reach')::numeric end;
  if reach > 0 and p_views / reach > (ops.cfg('trust.fraud.views_over_reach', '3'))::numeric then
    raised := trust.raise_flag('submission', s.id, 'FR-10', 60, jsonb_build_object('views', p_views, 'reach', reach))
              is not null or raised;
  end if;
  watch := case when jsonb_typeof(p_extra -> 'avg_watch_time') = 'number'
                then (p_extra ->> 'avg_watch_time')::numeric / case when s.platform = 'instagram' then 1000 else 1 end end;
  skip := case when jsonb_typeof(p_extra -> 'skip_rate') = 'number' then (p_extra ->> 'skip_rate')::numeric end;
  if p_views >= greatest(c.min_views, 1000)
     and (watch < (ops.cfg('trust.fraud.min_avg_watch_sec'))::numeric or skip > (ops.cfg('trust.fraud.max_skip_rate'))::numeric) then
    raised := trust.raise_flag('submission', s.id, 'FR-09', 50, jsonb_build_object('avg_watch_sec', watch, 'skip_rate', skip, 'snapshot_id', sid))
              is not null or raised;
  end if;
  if jsonb_typeof(p_extra -> 'countries') = 'object' then
    select coalesce(sum(x.value::numeric) filter (where upper(x.key) = 'ID'), 0), sum(x.value::numeric) into id_views, all_views
      from jsonb_each_text(p_extra -> 'countries') x where x.value ~ '^[0-9]+(\.[0-9]+)?$';
    if all_views > 0 and p_views >= greatest(c.min_views, 1000)
       and id_views / all_views < (ops.cfg('trust.fraud.min_id_country_share'))::numeric then
      raised := trust.raise_flag('submission', s.id, 'FR-11', 60,
                                 jsonb_build_object('id_share', round(id_views / all_views, 4), 'countries', p_extra -> 'countries',
                                                    'traffic_sources', p_extra -> 'traffic_sources', 'snapshot_id', sid)) is not null or raised;
      hold := true;  -- FR-11: tahan earning
    end if;
  end if;
  if fin and p_views < s.counted_views
     and (s.counted_views - p_views) * 100 >= s.counted_views * (ops.cfg('trust.fraud.lock_drop_pct', '20'))::numeric then
    -- FR-08: koreksi otomatis (accrue_earnings → correct_down); flag hanya catatan, tidak menahan release.
    perform trust.raise_flag('submission', s.id, 'FR-08', 40,
                             jsonb_build_object('counted_views', s.counted_views, 'final_views', p_views), 'actioned');
  end if;
  if hold and s.status = 'tracking' then
    update tracking.submissions set status = 'flagged' where id = s.id;
  end if;

  perform finance.accrue_earnings(s.id, sid);

  select t.status into st from tracking.submissions t where t.id = s.id;
  if fin and st = 'tracking' then
    update tracking.submissions set status = 'locked', locked_at = now() where id = s.id;
    st := 'locked';
  end if;
  if not fin and now() < window_end then
    select (e.value ->> 'every_hours')::numeric into every_h
      from jsonb_array_elements(ops.cfg('tracking.poll_schedule',
             '[{"until_hours":72,"every_hours":4},{"until_hours":336,"every_hours":24},{"until_hours":null,"every_hours":72}]'))
           with ordinality e(value, i)
     where e.value ->> 'until_hours' is null
        or (e.value ->> 'until_hours')::numeric > extract(epoch from now() - s.posted_at) / 3600
     order by e.i limit 1;
    nxt := least(now() + coalesce(every_h, 24) * interval '1 hour', window_end);
  end if;
  update tracking.submissions set last_snapshot_at = taken, next_poll_at = nxt where id = s.id;
  return jsonb_build_object('snapshot_id', sid, 'flagged', raised or st = 'flagged', 'next_poll_at', nxt, 'locked', st = 'locked');
end $function$;

CREATE OR REPLACE FUNCTION api.worker_submission_context (
  p_submission uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  a tracking.social_accounts;
  c market.campaigns;
  tok text;
begin
  select * into s from tracking.submissions t where t.id = p_submission;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  select * into a from tracking.social_accounts x where x.id = s.social_account_id;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  select ds.decrypted_secret into tok from vault.decrypted_secrets ds where ds.id = a.token_ref;
  return jsonb_build_object(
    'submission', jsonb_build_object('id', s.id, 'platform', s.platform, 'post_id', s.post_id, 'url', s.url, 'posted_at', s.posted_at,
                                     'status', s.status, 'user_id', s.user_id, 'campaign_id', s.campaign_id,
                                     'counted_views', s.counted_views, 'last_snapshot_at', s.last_snapshot_at),
    'account', jsonb_build_object('id', a.id, 'external_id', a.external_id, 'handle', a.handle, 'status', a.status),
    'token', tok,
    'campaign', jsonb_build_object('required_hashtags', c.required_hashtags, 'required_mentions', c.required_mentions,
                                   'required_links', c.required_links, 'min_duration_sec', c.min_duration_sec,
                                   'max_duration_sec', c.max_duration_sec, 'view_window_days', c.view_window_days,
                                   'status', c.status),
    'final', tracking.final_due(s.id));
end $function$;

CREATE OR REPLACE FUNCTION api.worker_unsubscribe (
  p_user uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  insert into ops.notification_prefs (user_id, email_promotions) values (p_user, false)
  on conflict (user_id) do update set email_promotions = false, updated_at = now();
end $function$;

CREATE OR REPLACE FUNCTION api.worker_upsert_social_account (
  p_user                uuid,
  p_platform            market.platform,
  p_external_id         text,
  p_handle              text,
  p_followers           integer,
  p_platform_created_at timestamp with time zone,
  p_token               text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  a tracking.social_accounts;
  aid uuid;
begin
  if not exists (select 1 from market.profiles pr where pr.id = p_user and pr.status = 'active') then
    raise exception 'profile_inactive' using errcode = 'P0001';
  end if;
  select * into a from tracking.social_accounts x where x.platform = p_platform and x.external_id = p_external_id for update;
  if found then
    if a.user_id <> p_user then
      raise exception 'social_taken' using errcode = 'P0001';
    end if;
    update tracking.social_accounts
       set handle = p_handle, followers = coalesce(p_followers, followers),
           platform_created_at = coalesce(p_platform_created_at, platform_created_at), status = 'verified', verified_at = now()
     where id = a.id;
    aid := a.id;
  else
    begin
      insert into tracking.social_accounts (user_id, platform, external_id, handle, followers, platform_created_at)
      values (p_user, p_platform, p_external_id, p_handle, p_followers, p_platform_created_at) returning id into aid;
    exception when unique_violation then
      raise exception 'social_taken' using errcode = 'P0001';
    end;
  end if;
  if p_token is not null then
    perform api.store_social_token(aid, p_token);
  end if;
  update tracking.submissions set next_poll_at = now()
   where social_account_id = aid and status in ('tracking', 'flagged') and next_poll_at is null;
  return aid;
end $function$;

CREATE OR REPLACE FUNCTION finance.account (
  p_owner_type  text,
  p_owner_id    uuid,
  p_reward_type uuid
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  aid uuid;
begin
  select a.id into aid from finance.ledger_accounts a
   where a.owner_type = p_owner_type and a.owner_id is not distinct from p_owner_id and a.reward_type_id = p_reward_type;
  if aid is null then
    insert into finance.ledger_accounts (owner_type, owner_id, reward_type_id) values (p_owner_type, p_owner_id, p_reward_type)
    on conflict on constraint ledger_accounts_one_per_owner do nothing
    returning id into aid;
    if aid is null then
      select a.id into aid from finance.ledger_accounts a
       where a.owner_type = p_owner_type and a.owner_id is not distinct from p_owner_id and a.reward_type_id = p_reward_type;
    end if;
  end if;
  return aid;
end $function$;

CREATE OR REPLACE FUNCTION finance.accrue_earnings (
  p_submission uuid,
  p_snapshot   bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  snap tracking.view_snapshots;
  c market.campaigns;
  r market.rate_rules;
  p finance.reward_pools;
  ce finance.clip_earnings;
  pct numeric := (ops.cfg('finance.settlement_threshold_pct', '5'))::numeric;
  entries jsonb := '[]';
  v bigint;
  base bigint;
  crossed boolean;
  view_based boolean;
  raw numeric;
  amt numeric;
  remaining numeric;
  in_settle boolean;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  select * into snap from tracking.view_snapshots vs where vs.id = p_snapshot and vs.submission_id = p_submission;
  if not found then
    raise exception 'not_found:snapshot' using errcode = 'P0002';
  end if;
  if s.status <> 'tracking' then
    return;  -- flagged/belum approved: Δ menunggu; dihitung dari counted_views saat kembali tracking
  end if;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  v := snap.views;
  base := s.counted_views;
  if snap.is_final and v < base then
    perform finance.correct_down(s.id, snap.id, v);
    update tracking.submissions set counted_views = v where id = s.id;
    return;
  end if;
  if not snap.is_final and snap.taken_at > s.posted_at + make_interval(days => c.view_window_days) then
    return;
  end if;
  crossed := v >= c.min_views;

  perform 1 from finance.reward_pools fp where fp.campaign_id = c.id order by fp.id for update;
  for r in select rr.* from market.rate_rules rr
            where rr.campaign_id = c.id and rr.effective_from <= snap.taken_at
              and (rr.effective_to is null or rr.effective_to > snap.taken_at)
              and (rr.platform is null or rr.platform = s.platform)
            order by rr.pool_id, rr.effective_from, rr.id loop
    select * into ce from finance.clip_earnings x where x.submission_id = s.id and x.rule_id = r.id;
    view_based := r.kind in ('per_1k_views', 'tiered_cpm');
    raw := case
      when r.kind = 'flat_per_post' then
        case when coalesce(ce.once_paid, false) then 0 else (r.params ->> 'amount')::numeric end
      when r.kind = 'milestone_bonus' then
        case when crossed and not coalesce(ce.once_paid, false) and base < (r.params ->> 'threshold')::numeric
                  and v >= (r.params ->> 'threshold')::numeric then (r.params ->> 'amount')::numeric else 0 end
      when crossed then finance.rule_amount(r.kind, r.params, base, v)
      else 0 end;
    continue when coalesce(raw, 0) <= 0;

    select * into p from finance.reward_pools fp where fp.id = r.pool_id;
    amt := trunc(least(raw, p.max_per_clip - coalesce((select sum(x.amount + x.demand) from finance.clip_earnings x
                                                        where x.submission_id = s.id and x.pool_id = p.id), 0)), 10);
    continue when amt <= 0;
    remaining := p.total - p.allocated;
    in_settle := exists (select 1 from finance.pool_settlements ps where ps.pool_id = p.id);
    if not in_settle and remaining > 0 and remaining * 100 < p.total * pct then
      perform finance.start_settlement(p.id);
      in_settle := true;
    end if;

    if in_settle then
      insert into finance.clip_earnings as x (submission_id, rule_id, pool_id, demand, demand_snapshot, views_from, views_to, once_paid)
      values (s.id, r.id, p.id, amt, snap.id, case when view_based then base end, case when view_based then v end, not view_based)
      on conflict (submission_id, rule_id) do update
        set demand = x.demand + excluded.demand, demand_snapshot = excluded.demand_snapshot,
            views_from = coalesce(x.views_from, excluded.views_from), views_to = coalesce(excluded.views_to, x.views_to),
            once_paid = x.once_paid or excluded.once_paid, updated_at = now();
      continue;
    end if;

    amt := least(amt, remaining);
    continue when amt <= 0;
    entries := entries || jsonb_build_array(
      finance.e(finance.account('campaign_pool', p.id, p.reward_type_id), -amt, 'accrual', snap.id || ':' || r.id),
      finance.e(finance.account('user_wallet', s.user_id, p.reward_type_id), amt, 'accrual', snap.id || ':' || r.id, 'pending'));
    update finance.reward_pools set allocated = allocated + amt where id = p.id;
    insert into finance.clip_earnings as x (submission_id, rule_id, pool_id, amount, views_from, views_to, once_paid)
    values (s.id, r.id, p.id, amt, case when view_based then base end, case when view_based then v end, not view_based)
    on conflict (submission_id, rule_id) do update
      set amount = x.amount + excluded.amount,
          views_from = coalesce(x.views_from, excluded.views_from), views_to = coalesce(excluded.views_to, x.views_to),
          once_paid = x.once_paid or excluded.once_paid, updated_at = now();
    if remaining - amt > 0 and (remaining - amt) * 100 < p.total * pct then
      perform finance.start_settlement(p.id);
    end if;
  end loop;

  if crossed and v > base then
    update tracking.submissions set counted_views = v where id = s.id;
  end if;
  perform finance.post(gen_random_uuid(), entries);
  perform finance.check_exhausted(c.id);
end $function$;

CREATE OR REPLACE FUNCTION finance.accrue_referral_bonus()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pct numeric := (ops.cfg('finance.referral_bonus_pct', '5'))::numeric;
  idr uuid := finance.idr();
  rev uuid;
  x record;
  bonus numeric;
begin
  if pct <= 0 then
    return;
  end if;
  rev := finance.account('platform_revenue', null, idr);
  for x in select le.id as entry_id, le.amount, r.referrer_id
             from market.referrals r
             join market.profiles rf on rf.id = r.referrer_id and rf.status = 'active'
             join finance.ledger_accounts a on a.owner_type = 'user_wallet' and a.owner_id = r.referred_id and a.reward_type_id = idr
             join finance.ledger_entries le on le.account_id = a.id and le.state = 'available' and le.ref_type = 'release'
            where r.qualified_at is not null and r.bonus_until is not null and le.amount > 0
              and le.created_at >= r.qualified_at and le.created_at < r.bonus_until
              and not exists (select 1 from finance.ledger_entries b where b.ref_type = 'referral_bonus' and b.ref_id = le.id::text)
            order by le.id loop
    bonus := trunc(x.amount * pct / 100);
    continue when bonus <= 0;
    perform finance.post(gen_random_uuid(), jsonb_build_array(
      finance.e(rev, -bonus, 'referral_bonus', x.entry_id::text),
      finance.e(finance.account('user_wallet', x.referrer_id, idr), bonus, 'referral_bonus', x.entry_id::text, 'available')));
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION finance.amount_ref (
  p_reward_type uuid,
  p_amount      numeric
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return (select jsonb_build_object('amount', trim_scale(p_amount), 'reward_type', rt.code, 'unit_label', rt.unit_label)
            from market.reward_types rt where rt.id = p_reward_type);
end $function$;

CREATE OR REPLACE FUNCTION finance.balance (
  p_account uuid,
  p_state   finance.earning_state DEFAULT NULL::finance.earning_state
)
  RETURNS numeric
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return coalesce((select sum(e.amount) from finance.ledger_entries e
                   where e.account_id = p_account and e.state is not distinct from p_state), 0);
end $function$;

CREATE OR REPLACE FUNCTION finance.campaign_budget_idr (
  p_campaign uuid
)
  RETURNS numeric
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  select coalesce(sum(pl.total), 0)
    from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
   where pl.campaign_id = p_campaign and rt.code = 'IDR' and rt.owner_org_id is null;
$function$;

CREATE OR REPLACE FUNCTION finance.check_entry_bucket()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if ((select a.owner_type from finance.ledger_accounts a where a.id = new.account_id) = 'user_wallet')
     is distinct from (new.state is not null) then
    raise exception 'state wajib untuk akun user_wallet dan hanya untuk akun itu' using errcode = '23514';
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION finance.check_exhausted (
  p_campaign uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if exists (select 1 from finance.reward_pools rp where rp.campaign_id = p_campaign)
     and not exists (select 1 from finance.reward_pools rp where rp.campaign_id = p_campaign and rp.allocated < rp.total)
     and not exists (select 1 from finance.pool_settlements ps join finance.reward_pools rp on rp.id = ps.pool_id
                     where rp.campaign_id = p_campaign) then
    update market.campaigns set status = 'exhausted' where id = p_campaign and status in ('live', 'paused', 'tracking');
  end if;
end $function$;

CREATE OR REPLACE FUNCTION finance.check_txn_balanced()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if exists (select 1 from finance.ledger_entries e where e.txn_id = new.txn_id
             group by e.reward_type_id having sum(e.amount) <> 0) then
    raise exception 'transaksi % tidak seimbang (jumlah per reward type harus 0)', new.txn_id using errcode = '23514';
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION finance.correct_down (
  p_submission uuid,
  p_snapshot   bigint,
  p_views      bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  x record;
  sub record;
  total numeric;
  target numeric;
  diff numeric;
  from_demand numeric;
  from_amount numeric;
  entries jsonb := '[]';
begin
  select t.user_id, t.campaign_id, k.min_views into sub
    from tracking.submissions t join market.campaigns k on k.id = t.campaign_id where t.id = p_submission;
  perform 1 from finance.reward_pools fp where fp.campaign_id = sub.campaign_id order by fp.id for update;
  for x in select ce.*, rr.kind, rr.params, rp.reward_type_id from finance.clip_earnings ce
             join market.rate_rules rr on rr.id = ce.rule_id join finance.reward_pools rp on rp.id = ce.pool_id
            where ce.submission_id = p_submission and ce.released_at is null and ce.amount + ce.demand > 0
            order by ce.pool_id, ce.rule_id loop
    total := x.amount + x.demand;
    target := case
      when x.kind = 'flat_per_post' then total
      when x.kind = 'milestone_bonus' then
        case when p_views >= greatest(sub.min_views, (x.params ->> 'threshold')::numeric) then total else 0 end
      when p_views < sub.min_views then 0
      else least(total, trunc(finance.rule_amount(x.kind, x.params, x.views_from, least(x.views_to, p_views)), 10)) end;
    diff := total - target;
    continue when diff <= 0;
    from_demand := least(x.demand, diff);
    from_amount := diff - from_demand;
    update finance.clip_earnings ce set demand = ce.demand - from_demand, amount = ce.amount - from_amount,
           views_to = least(ce.views_to, p_views), updated_at = now()
     where ce.submission_id = x.submission_id and ce.rule_id = x.rule_id;
    if from_amount > 0 then
      entries := entries || jsonb_build_array(
        finance.e(finance.account('user_wallet', sub.user_id, x.reward_type_id), -from_amount, 'reversal',
                  p_snapshot || ':' || x.rule_id, 'pending'),
        finance.e(finance.account('campaign_pool', x.pool_id, x.reward_type_id), from_amount, 'reversal',
                  p_snapshot || ':' || x.rule_id));
      update finance.reward_pools set allocated = allocated - from_amount where id = x.pool_id;
    end if;
  end loop;
  perform finance.post(gen_random_uuid(), entries);
end $function$;

CREATE OR REPLACE FUNCTION finance.create_fee_rule (
  p_scope text,
  p       jsonb,
  p_base  finance.fee_rules,
  p_actor uuid
)
  RETURNS uuid
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  rid uuid;
begin
  if jsonb_typeof(p) is distinct from 'object' then
    perform market.fail('invalid:fee_rule', 'fee rule harus object');
  end if;
  insert into finance.fee_rules (scope, mgmt_fee_pct, admin_fee_pct, clipper_fee_pct, instant_withdraw_fee, created_by)
  values (p_scope,
          coalesce(market.jnum(p -> 'mgmt_fee_pct'), p_base.mgmt_fee_pct, 15),
          coalesce(market.jnum(p -> 'admin_fee_pct'), p_base.admin_fee_pct, 5),
          coalesce(market.jnum(p -> 'clipper_fee_pct'), p_base.clipper_fee_pct, 0),
          case when p ? 'instant_withdraw_fee' then market.jnum(p -> 'instant_withdraw_fee') else p_base.instant_withdraw_fee end,
          p_actor)
  returning id into rid;
  return rid;
end $function$;

CREATE OR REPLACE FUNCTION finance.e (
  p_account  uuid,
  p_amount   numeric,
  p_ref_type text,
  p_ref_id   text,
  p_state    text    DEFAULT NULL::text
)
  RETURNS jsonb
  LANGUAGE plpgsql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
begin
  return jsonb_build_object('account', p_account, 'amount', p_amount, 'ref_type', p_ref_type, 'ref_id', p_ref_id, 'state', p_state);
end $function$;

CREATE OR REPLACE FUNCTION finance.effective_fee_rule (
  p_org      uuid,
  p_campaign uuid
)
  RETURNS finance.fee_rules
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  select f.* from finance.fee_rules f
   where f.id = coalesce((select c.fee_rule_id from market.campaigns c where c.id = p_campaign),
                         (select o.fee_rule_id from market.organizations o where o.id = p_org),
                         (select g.id from finance.fee_rules g where g.scope = 'global'));
$function$;

CREATE OR REPLACE FUNCTION finance.fee_rule_visible (
  p_rule uuid
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return exists (select 1 from market.organizations o where o.fee_rule_id = p_rule and ops.is_org_member(o.id))
      or exists (select 1 from market.campaigns c where c.fee_rule_id = p_rule and ops.is_org_member(c.org_id));
end $function$;

CREATE OR REPLACE FUNCTION finance.finalize_settlements()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  wait interval := (ops.cfg('finance.settlement_wait_hours', '6'))::numeric * interval '1 hour';
  st record;
begin
  for st in select ps.pool_id from finance.pool_settlements ps join finance.reward_pools rp on rp.id = ps.pool_id
             where ps.cutoff_at <= now() - wait
                or not exists (select 1 from tracking.submissions t
                               where t.campaign_id = rp.campaign_id and t.status = 'tracking' and t.next_poll_at is not null
                                 and coalesce(t.last_snapshot_at, '-infinity') < ps.cutoff_at)
             order by ps.pool_id loop
    perform finance.settle_pool(st.pool_id);
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION finance.idr()
  RETURNS uuid
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  rid uuid := (select rt.id from market.reward_types rt where rt.code = 'IDR' and rt.owner_org_id is null);
begin
  if rid is null then
    raise exception 'reward type IDR global belum ada (seed)' using errcode = 'P0002';
  end if;
  return rid;
end $function$;

CREATE OR REPLACE FUNCTION finance.issue_invoice (
  p_org         uuid,
  p_campaign    uuid,
  p_kind        text,
  p_subtotal    numeric,
  p_service_fee numeric                  DEFAULT 0,
  p_pin_until   timestamp with time zone DEFAULT NULL::timestamp WITH time zone,
  p_pool_topups jsonb                    DEFAULT NULL::jsonb
)
  RETURNS finance.invoices
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  fr finance.fee_rules;
  sub numeric := round(coalesce(p_subtotal, 0), 2);
  svc numeric := round(coalesce(p_service_fee, 0), 2);
  mgmt numeric := 0;
  adm numeric := 0;
  base numeric;
  tx numeric;
  tax_pct numeric := coalesce((select (s.value #>> '{}')::numeric from ops.settings s where s.key = 'public.billing.tax_pct'), 11);
  due_days int := coalesce((select (s.value #>> '{}')::int from ops.settings s where s.key = 'public.billing.invoice_due_days'), 7);
  inv finance.invoices;
begin
  if p_kind in ('campaign', 'topup') then
    fr := finance.effective_fee_rule(p_org, p_campaign);
    if fr.id is null then
      perform market.fail('config:fee_rule_missing', 'fee rule global belum ada (seed)');
    end if;
    if p_kind = 'topup' and p_pool_topups is not null then
      sub := round(finance.topup_cash_idr(p_campaign, p_pool_topups), 2);
      base := sub + finance.noncash_value_idr(p_campaign, p_pool_topups);
    else
      base := sub + case when p_kind = 'campaign' then finance.noncash_value_idr(p_campaign) else 0 end;
    end if;
    mgmt := round(base * fr.mgmt_fee_pct / 100, 2);
    adm := round(base * fr.admin_fee_pct / 100, 2);
  elsif sub <> 0 then
    perform market.fail('invalid:subtotal', 'invoice pinned/managed_service tanpa subtotal');
  end if;
  tx := round((mgmt + adm + svc) * tax_pct / 100, 2);
  insert into finance.invoices (number, org_id, campaign_id, kind, subtotal, mgmt_fee, admin_fee, service_fee, tax, total, due_at,
                                pin_until, pool_topups)
  values (finance.next_invoice_number(), p_org, p_campaign, p_kind, sub, mgmt, adm, svc, tx, sub + mgmt + adm + svc + tx,
          now() + make_interval(days => due_days), p_pin_until, p_pool_topups)
  returning * into inv;
  perform market.notify_org(p_org, array['brand_owner', 'brand_finance']::market.org_role[], 'invoice.issued',
                            jsonb_build_object('invoice_id', inv.id, 'invoice_number', inv.number, 'kind', inv.kind,
                                               'total', inv.total, 'due_at', inv.due_at, 'campaign_id', inv.campaign_id,
                                               'campaign_title', (select c.title from market.campaigns c where c.id = inv.campaign_id)));
  return inv;
end $function$;

CREATE OR REPLACE FUNCTION finance.next_invoice_number()
  RETURNS text
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
  select 'INV-' || to_char(now() at time zone 'Asia/Jakarta', 'YYYYMM') || '-'
         || lpad(nextval('finance.invoice_number_seq')::text, 6, '0');
$function$;

CREATE OR REPLACE FUNCTION finance.noncash_value_idr (
  p_campaign uuid,
  p_items    jsonb DEFAULT NULL::jsonb
)
  RETURNS numeric
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  select coalesce(sum(coalesce((e ->> 'amount')::numeric, pl.total) * rt.idr_value_per_unit), 0)
    from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
    left join lateral jsonb_array_elements(p_items) e on (e ->> 'pool_id')::uuid = pl.id
   where pl.campaign_id = p_campaign and not (rt.code = 'IDR' and rt.owner_org_id is null)
     and (p_items is null or e is not null);
$function$;

CREATE OR REPLACE FUNCTION finance.on_campaign_cancelled()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  perform finance.refund_cancelled_campaign(new.id);
  return null;
end $function$;

CREATE OR REPLACE FUNCTION finance.pay_refund (
  p_refund    uuid,
  p_proof_ref text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r finance.org_refunds;
  idr uuid := finance.idr();
begin
  select * into r from finance.org_refunds o where o.id = p_refund for update;
  if not found then
    raise exception 'not_found:refund' using errcode = 'P0002';
  end if;
  if r.status = 'paid' then
    return;
  end if;
  if r.status <> 'approved' then
    raise exception 'invalid_state:%', r.status using errcode = 'P0001';
  end if;
  update finance.org_refunds set status = 'paid', paid_at = now(), proof_ref = p_proof_ref where id = r.id;
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(finance.account('org_credit', r.org_id, idr), -r.amount, 'refund', r.id || ':paid'),
    finance.e(finance.account('bank_clearing', null, idr), r.amount - r.transfer_fee, 'refund', r.id || ':paid'),
    finance.e(finance.account('platform_revenue', null, idr), r.transfer_fee, 'refund', r.id || ':paid')));
  perform market.notify_org(r.org_id, array['brand_owner', 'brand_finance']::market.org_role[], 'refund.paid',
                            market.campaign_ref(r.campaign_id) || finance.amount_ref(idr, r.amount - r.transfer_fee)
                            || jsonb_build_object('refund_id', r.id, 'transfer_fee', r.transfer_fee));
end $function$;

CREATE OR REPLACE FUNCTION finance.post (
  p_txn     uuid,
  p_entries jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if exists (select 1 from jsonb_to_recordset(p_entries) x(account uuid)
             where not exists (select 1 from finance.ledger_accounts a where a.id = x.account)) then
    raise exception 'akun ledger tidak ada dalam transaksi %', p_txn using errcode = '23503';
  end if;
  if exists (select 1 from jsonb_to_recordset(p_entries) x(account uuid, amount numeric)
             join finance.ledger_accounts a on a.id = x.account
             group by a.reward_type_id having sum(x.amount) <> 0) then
    raise exception 'transaksi % tidak seimbang', p_txn using errcode = '23514';
  end if;
  insert into finance.ledger_entries (txn_id, account_id, reward_type_id, amount, state, ref_type, ref_id)
  select p_txn, x.account, a.reward_type_id, x.amount, x.state::finance.earning_state, x.ref_type, x.ref_id
    from jsonb_to_recordset(p_entries) x(account uuid, amount numeric, state text, ref_type text, ref_id text)
    join finance.ledger_accounts a on a.id = x.account
   where x.amount <> 0;
end $function$;

CREATE OR REPLACE FUNCTION finance.refund_cancelled_campaign (
  p_campaign uuid
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  c market.campaigns;
  idr uuid := finance.idr();
  key text := 'cancel:' || p_campaign;
  rid uuid;
  fees numeric;
  tx numeric;
  pool_idr numeric := 0;
  refund_amount numeric;
  x record;
  pools jsonb := '[]';
  entries jsonb := '[]';
begin
  select * into c from market.campaigns k where k.id = p_campaign;
  if not found or c.status <> 'cancelled' then
    raise exception 'invalid_state:%', coalesce(c.status::text, 'missing') using errcode = 'P0001';
  end if;
  update finance.invoices set status = 'void' where campaign_id = c.id and status = 'issued';
  select r.id into rid from finance.org_refunds r where r.idempotency_key = key;
  if rid is not null then
    return rid;
  end if;
  select coalesce(sum(i.mgmt_fee + i.admin_fee + i.service_fee + case when i.kind = 'pinned' then i.subtotal else 0 end), 0),
         coalesce(sum(i.tax), 0)
    into fees, tx
    from finance.invoices i where i.campaign_id = c.id and i.status = 'paid' and i.kind in ('campaign', 'topup', 'pinned');
  perform 1 from finance.reward_pools rp where rp.campaign_id = c.id order by rp.id for update;
  for x in select rp.reward_type_id as rt, a.id as account, finance.balance(a.id) as bal
             from finance.reward_pools rp
             join finance.ledger_accounts a on a.owner_type = 'campaign_pool' and a.owner_id = rp.id
            where rp.campaign_id = c.id and finance.balance(a.id) > 0 order by rp.id loop
    pools := pools || jsonb_build_array(jsonb_build_object('rt', x.rt, 'account', x.account, 'bal', x.bal));
    if x.rt = idr then
      pool_idr := pool_idr + x.bal;
    end if;
  end loop;
  refund_amount := pool_idr + fees + tx;
  if refund_amount <= 0 and pools = '[]' then
    return null;  -- belum ada yang dibayar
  end if;
  if refund_amount > 0 then
    insert into finance.org_refunds (org_id, campaign_id, amount, transfer_fee, requested_by, idempotency_key)
    values (c.org_id, c.id, refund_amount, 0, coalesce((select auth.uid()), c.created_by), key) returning id into rid;
  else
    rid := gen_random_uuid();  -- hanya stok non-tunai yang dikembalikan
  end if;
  for x in select (p ->> 'rt')::uuid as rt, (p ->> 'account')::uuid as account, (p ->> 'bal')::numeric as bal
             from jsonb_array_elements(pools) p loop
    entries := entries || jsonb_build_array(finance.e(x.account, -x.bal, 'refund', rid::text));
    if x.rt <> idr then
      entries := entries || jsonb_build_array(finance.e(finance.account('bank_clearing', null, x.rt), x.bal, 'refund', rid::text));
    end if;
  end loop;
  entries := entries || jsonb_build_array(
    finance.e(finance.account('platform_revenue', null, idr), -fees, 'refund', rid::text),
    finance.e(finance.account('tax_payable', null, idr), -tx, 'refund', rid::text),
    finance.e(finance.account('org_credit', c.org_id, idr), refund_amount, 'refund', rid::text));
  perform finance.post(gen_random_uuid(), entries);
  if refund_amount > 0 then
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_finance']::market.org_role[], 'refund.requested',
                              market.campaign_ref(c.id) || finance.amount_ref(idr, refund_amount) || jsonb_build_object('refund_id', rid));
    return rid;
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION finance.release_earnings()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  hold int := (ops.cfg('finance.hold_days', '7'))::int;
  s record;
  g record;
  wallet uuid;
  avail numeric;
  entries jsonb;
  released jsonb;
begin
  for s in select t.id, t.user_id, t.campaign_id from tracking.submissions t
            where t.status = 'locked' and t.locked_at <= now() - make_interval(days => hold)
              and not exists (select 1 from trust.fraud_flags f where f.status in ('open', 'held')
                              and ((f.target_type = 'submission' and f.target_id = t.id)
                                or (f.target_type = 'profile' and f.target_id = t.user_id)
                                or (f.target_type = 'social_account' and f.target_id = t.social_account_id)))
              and not exists (select 1 from finance.clip_earnings ce where ce.submission_id = t.id and ce.demand > 0)
            order by t.locked_at limit 1000
            for update of t skip locked loop
    entries := '[]';
    released := '{}';
    perform 1 from finance.reward_pools fp where fp.campaign_id = s.campaign_id order by fp.id for update;
    for g in select ce.pool_id, rp.reward_type_id, rt.code, rt.decimals, sum(ce.amount) as amount
               from finance.clip_earnings ce join finance.reward_pools rp on rp.id = ce.pool_id
               join market.reward_types rt on rt.id = rp.reward_type_id
              where ce.submission_id = s.id and ce.released_at is null
              group by ce.pool_id, rp.reward_type_id, rt.code, rt.decimals having sum(ce.amount) > 0
              order by ce.pool_id loop
      wallet := finance.account('user_wallet', s.user_id, g.reward_type_id);
      avail := trunc(g.amount, g.decimals);
      entries := entries || jsonb_build_array(
        finance.e(wallet, -g.amount, 'release', s.id || ':' || g.pool_id, 'pending'),
        finance.e(wallet, avail, 'release', s.id || ':' || g.pool_id, 'available'),
        finance.e(finance.account('campaign_pool', g.pool_id, g.reward_type_id), g.amount - avail, 'release', s.id || ':' || g.pool_id));
      if g.amount > avail then
        update finance.reward_pools set allocated = allocated - (g.amount - avail) where id = g.pool_id;
      end if;
      if avail > 0 then
        released := released || jsonb_build_object(g.reward_type_id::text,
                                                    coalesce((released ->> g.reward_type_id::text)::numeric, 0) + avail);
      end if;
    end loop;
    update finance.clip_earnings set released_at = now() where submission_id = s.id and released_at is null;
    update tracking.submissions set status = 'settled' where id = s.id;
    perform finance.post(gen_random_uuid(), entries);
    if released <> '{}' then
      perform ops.enqueue_notification(s.user_id, 'earning.available', market.campaign_ref(s.campaign_id) || jsonb_build_object(
        'submission_id', s.id,
        'amounts', (select jsonb_agg(finance.amount_ref(x.key::uuid, x.value::numeric)) from jsonb_each_text(released) x)));
    end if;
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION finance.require_active_clipper()
  RETURNS market.profiles
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pr market.profiles;
begin
  if (select auth.uid()) is null or not ops.iss_ok() then
    raise exception 'auth:no_session' using errcode = '42501';
  end if;
  select * into pr from market.profiles where id = (select auth.uid());
  if not found or not (pr.status = 'active' or (pr.status = 'suspended' and pr.suspended_until <= now())) then
    raise exception 'profile_inactive' using errcode = 'P0001';
  end if;
  return pr;
end $function$;

CREATE OR REPLACE FUNCTION finance.retry_instant_payouts()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r record;
  n int := 0;
  old int := 0;
begin
  for r in select p.id, p.created_at from finance.payouts p
            where p.channel = 'instant' and p.status in ('requested', 'processing') and p.provider_ref is null
              and p.created_at <= now() - interval '15 minutes'
            order by p.created_at limit 200 loop
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'disburse', 'payout_id', r.id));
    n := n + 1;
    if r.created_at <= now() - interval '1 hour' then
      old := old + 1;
    end if;
  end loop;
  if old > 0 then
    perform ops.raise_alert('payout.instant_stuck', 'warning', jsonb_build_object('count', old), interval '6 hours');
  end if;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION finance.return_payout (
  p_payout uuid,
  p_error  text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  po finance.payouts;
  idr uuid := finance.idr();
begin
  select * into po from finance.payouts p where p.id = p_payout for update;
  if po.status = 'returned' then
    return;
  end if;
  if po.status in ('processing', 'paid') then
    update finance.payouts set status = 'failed' where id = po.id;
  end if;
  update finance.payouts set status = 'returned' where id = po.id;  -- trigger S-05 menolak kalau bukan dari failed
  perform finance.unwind_payout_journal(po);
  perform ops.enqueue_notification(po.user_id, 'payout.failed', finance.amount_ref(idr, po.amount)
                                   || jsonb_build_object('payout_id', po.id, 'channel', po.channel, 'reason', left(p_error, 200)));
  perform ops.raise_alert('payout.failed', 'warning', jsonb_build_object('payout_id', po.id, 'channel', po.channel,
                                                                           'amount', po.amount, 'error', left(p_error, 500)));
end $function$;

CREATE OR REPLACE FUNCTION finance.reverse_earning (
  p_submission uuid,
  p_reason     text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  x record;
  txn uuid := gen_random_uuid();
  entries jsonb := '[]';
  reversed jsonb := '{}';
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  perform 1 from finance.reward_pools fp where fp.campaign_id = s.campaign_id order by fp.id for update;
  for x in select ce.rule_id, ce.pool_id, ce.amount, rp.reward_type_id from finance.clip_earnings ce
             join finance.reward_pools rp on rp.id = ce.pool_id
            where ce.submission_id = s.id and ce.released_at is null and (ce.amount > 0 or ce.demand > 0)
            order by ce.pool_id, ce.rule_id loop
    if x.amount > 0 then
      entries := entries || jsonb_build_array(
        finance.e(finance.account('user_wallet', s.user_id, x.reward_type_id), -x.amount, 'reversal',
                  s.id || ':' || x.rule_id || ':' || txn, 'pending'),
        finance.e(finance.account('campaign_pool', x.pool_id, x.reward_type_id), x.amount, 'reversal',
                  s.id || ':' || x.rule_id || ':' || txn));
      update finance.reward_pools set allocated = allocated - x.amount where id = x.pool_id;
      reversed := reversed || jsonb_build_object(x.reward_type_id::text,
                                                 coalesce((reversed ->> x.reward_type_id::text)::numeric, 0) + x.amount);
    end if;
    update finance.clip_earnings ce set amount = 0, demand = 0, updated_at = now()
     where ce.submission_id = s.id and ce.rule_id = x.rule_id;
  end loop;
  perform finance.post(txn, entries);
  if reversed <> '{}' then
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values ((select auth.uid()), 'earning.reverse', 'submission:' || s.id, null,
            jsonb_build_object('reason', p_reason, 'txn_id', txn, 'amounts', reversed));
  end if;
end $function$;

CREATE OR REPLACE FUNCTION finance.rule_amount (
  p_kind   text,
  p_params jsonb,
  p_from   bigint,
  p_to     bigint
)
  RETURNS numeric
  LANGUAGE plpgsql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
declare
  t jsonb;
  lo numeric;
  hi numeric;
  total numeric := 0;
begin
  if p_from is null or p_to is null or p_to <= p_from then
    return 0;
  end if;
  if p_kind = 'per_1k_views' then
    return (p_to - p_from) * (p_params ->> 'rate')::numeric / 1000;
  elsif p_kind = 'tiered_cpm' then
    for t in select x.value from jsonb_array_elements(p_params -> 'tiers') x loop
      lo := greatest(p_from, coalesce((t ->> 'from')::numeric, 0));
      hi := least(p_to, coalesce((t ->> 'to')::numeric, p_to));
      if hi > lo then
        total := total + (hi - lo) * (t ->> 'rate')::numeric / 1000;
      end if;
    end loop;
    return total;
  end if;
  return 0;
end $function$;

CREATE OR REPLACE FUNCTION finance.settle_pool (
  p_pool uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  p finance.reward_pools;
  rem numeric;
  dsum numeric;
  paid numeric := 0;
  x record;
  entries jsonb := '[]';
  unit constant numeric := 0.0000000001;
begin
  select * into p from finance.reward_pools fp where fp.id = p_pool for update;
  rem := p.total - p.allocated;
  select coalesce(sum(ce.demand), 0) into dsum from finance.clip_earnings ce where ce.pool_id = p.id and ce.demand > 0;
  if dsum > 0 then
    for x in with dm as (
               select ce.submission_id, ce.rule_id, ce.demand, ce.demand_snapshot, t.user_id,
                      case when dsum <= rem then ce.demand else trunc(ce.demand * rem / dsum, 10) end as share
                 from finance.clip_earnings ce join tracking.submissions t on t.id = ce.submission_id
                where ce.pool_id = p.id and ce.demand > 0),
             k as (select case when dsum <= rem then 0 else round((rem - sum(dm.share)) / unit) end as n from dm)
             select dm.*, dm.share + case when row_number() over (order by dm.demand - dm.share desc, dm.submission_id, dm.rule_id)
                                               <= k.n then unit else 0 end as pay
               from dm cross join k loop
      if x.pay > 0 then
        entries := entries || jsonb_build_array(
          finance.e(finance.account('campaign_pool', p.id, p.reward_type_id), -x.pay, 'accrual', x.demand_snapshot || ':' || x.rule_id),
          finance.e(finance.account('user_wallet', x.user_id, p.reward_type_id), x.pay, 'accrual',
                    x.demand_snapshot || ':' || x.rule_id, 'pending'));
      end if;
      update finance.clip_earnings ce set amount = ce.amount + x.pay, demand = 0, updated_at = now()
       where ce.submission_id = x.submission_id and ce.rule_id = x.rule_id;
      paid := paid + x.pay;
    end loop;
    update finance.reward_pools set allocated = allocated + paid where id = p.id;
    perform finance.post(gen_random_uuid(), entries);
  end if;
  delete from finance.pool_settlements where pool_id = p.id;
  perform finance.check_exhausted(p.campaign_id);
end $function$;

CREATE OR REPLACE FUNCTION finance.start_settlement (
  p_pool uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  insert into finance.pool_settlements (pool_id, cutoff_at) values (p_pool, now()) on conflict (pool_id) do nothing;
  if found then
    update tracking.submissions t set next_poll_at = now()
     where t.id in (select o.id from tracking.submissions o join finance.reward_pools rp on rp.campaign_id = o.campaign_id
                    where rp.id = p_pool and o.status = 'tracking' and o.next_poll_at > now()
                    for update of o skip locked);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION finance.topup_cash_idr (
  p_campaign uuid,
  p_items    jsonb
)
  RETURNS numeric
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  select coalesce(sum((e ->> 'amount')::numeric), 0)
    from jsonb_array_elements(coalesce(p_items, '[]')) e
    join finance.reward_pools pl on pl.id = (e ->> 'pool_id')::uuid and pl.campaign_id = p_campaign
    join market.reward_types rt on rt.id = pl.reward_type_id
   where rt.code = 'IDR' and rt.owner_org_id is null;
$function$;

CREATE OR REPLACE FUNCTION finance.unwind_payout_journal (
  po finance.payouts
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  idr uuid := finance.idr();
  wallet uuid := finance.account('user_wallet', po.user_id, idr);
begin
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(wallet, -(po.amount - po.fee), 'payout_return', po.id::text, 'withdrawn'),
    finance.e(finance.account('platform_revenue', null, idr), -po.fee, 'payout_return', po.id::text),
    finance.e(wallet, po.amount, 'payout_return', po.id::text, 'available')));
end $function$;

CREATE OR REPLACE FUNCTION market.announce_campaign (
  p_campaign uuid
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  n int;
begin
  select count(ops.enqueue_notification(p.id, 'campaign.new', x.payload)) into n
    from market.campaigns c
    cross join lateral (select jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'campaign_slug', c.slug,
                                                  'org_name', (select o.name from market.organizations o where o.id = c.org_id),
                                                  'platforms', to_jsonb(c.platforms)) as payload) x
    join market.profiles p on p.status = 'active' and p.trust_score >= c.min_trust_score
   where c.id = p_campaign and not c.is_template
     and not exists (select 1 from market.org_members m where m.org_id = c.org_id and m.user_id = p.id)
     and (c.visibility <> 'invite' or exists (select 1 from market.campaign_invites i where i.campaign_id = c.id and i.user_id = p.id))
     and exists (select 1 from tracking.social_accounts a
                 where a.user_id = p.id and a.status = 'verified' and a.platform = any (c.platforms)
                   and coalesce(a.followers, 0) >= c.min_followers
                   and (c.min_account_age_days = 0
                        or a.platform_created_at <= now() - make_interval(days => c.min_account_age_days)));
  return n;
end $function$;

CREATE OR REPLACE FUNCTION market.campaign_budget (
  p_campaign uuid
)
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  with rules as (
    select r.id, r.kind, r.platform, r.reward_type_id, r.pool_id, r.params, r.effective_from, rt.code, rt.unit_label, rt.decimals,
           market.rule_rate(r.kind, r.params) as rate
      from market.rate_rules r join market.reward_types rt on rt.id = r.reward_type_id
     where r.campaign_id = p_campaign and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
  ), pools as (
    select pl.id, pl.reward_type_id, pl.total, pl.allocated, pl.total - pl.allocated as remaining, pl.max_per_clip,
           rt.code, rt.unit_label, rt.decimals, rt.idr_value_per_unit
      from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
     where pl.campaign_id = p_campaign
  ), est as (
    select pl.id as pool_id, pf.p as platform, floor(pl.remaining * 1000 / sum(r.rate))::bigint as views
      from pools pl
      cross join unnest((select c.platforms from market.campaigns c where c.id = p_campaign)) pf(p)
      join rules r on r.pool_id = pl.id and r.rate > 0 and (r.platform is null or r.platform = pf.p)
     group by pl.id, pf.p, pl.remaining
  )
  select jsonb_build_object(
    'pools', coalesce((select jsonb_agg(jsonb_build_object(
                'pool_id', pl.id, 'reward_type_id', pl.reward_type_id, 'code', pl.code, 'unit_label', pl.unit_label,
                'decimals', pl.decimals, 'idr_value_per_unit', trim_scale(pl.idr_value_per_unit), 'total', trim_scale(pl.total),
                'allocated', trim_scale(pl.allocated), 'remaining', trim_scale(pl.remaining),
                'max_per_clip', trim_scale(pl.max_per_clip),
                'est_remaining_views', coalesce((select jsonb_object_agg(e.platform, e.views) from est e where e.pool_id = pl.id),
                                                '{}'::jsonb)) order by pl.code, pl.id) from pools pl), '[]'::jsonb),
    'rates', coalesce((select jsonb_agg(jsonb_build_object(
                'rule_id', r.id, 'kind', r.kind, 'platform', r.platform, 'reward_type_id', r.reward_type_id, 'code', r.code,
                'unit_label', r.unit_label, 'decimals', r.decimals, 'pool_id', r.pool_id, 'params', r.params,
                'effective_from', r.effective_from) order by r.platform nulls first, r.code, r.kind, r.id) from rules r), '[]'::jsonb),
    'budget_idr', coalesce((select trim_scale(round(sum(pl.total * pl.idr_value_per_unit), 2)) from pools pl), 0),
    'spent_idr', coalesce((select trim_scale(round(sum(pl.allocated * pl.idr_value_per_unit), 2)) from pools pl), 0),
    'remaining_idr', coalesce((select trim_scale(round(sum(pl.remaining * pl.idr_value_per_unit), 2)) from pools pl), 0),
    'est_remaining_views', coalesce((select jsonb_object_agg(x.platform, x.views)
                                       from (select e.platform, max(e.views) as views from est e group by e.platform) x), '{}'::jsonb));
$function$;

CREATE OR REPLACE FUNCTION market.campaign_projection (
  p_campaign uuid
)
  RETURNS jsonb
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  with b as (
    select coalesce(sum(pl.total * rt.idr_value_per_unit), 0) as budget, coalesce(sum(pl.allocated * rt.idr_value_per_unit), 0) as spent
      from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
     where pl.campaign_id = p_campaign
  ), t as (
    select c.status, c.submit_deadline, b.budget, b.spent,
           greatest(extract(epoch from now() - coalesce(c.start_at, c.created_at)) / 86400, 0) as elapsed,
           c.submit_deadline + make_interval(days => c.view_window_days) as horizon
      from market.campaigns c cross join b
     where c.id = p_campaign
  ), x as (
    select t.*, t.spent / greatest(t.elapsed, 1) as daily,
           coalesce(greatest(extract(epoch from t.horizon - now()) / 86400, 0), 0) as days_left
      from t
  )
  select jsonb_build_object(
    'budget_idr', trim_scale(round(x.budget, 2)),
    'spent_idr', trim_scale(round(x.spent, 2)),
    'remaining_idr', trim_scale(round(x.budget - x.spent, 2)),
    'utilization_pct', case when x.budget > 0 then trim_scale(round(x.spent / x.budget * 100, 2)) end,
    'elapsed_days', trim_scale(round(x.elapsed, 2)),
    'daily_spend_idr', trim_scale(round(x.daily, 2)),
    'submit_deadline', x.submit_deadline,
    'horizon_at', x.horizon,
    'projected_utilization_pct', case when x.budget > 0
                                      then trim_scale(round(least(x.budget, x.spent + x.daily * x.days_left) / x.budget * 100, 2)) end,
    'projected_exhaust_at', case when x.daily > 0 and x.budget > x.spent
                                 then now() + make_interval(days => ceil(least((x.budget - x.spent) / x.daily, 3650))::int) end,
    'exhausts_before_horizon', case when x.horizon is not null and x.budget > 0
                                    then x.spent + x.daily * x.days_left >= x.budget end)
  from x;
$function$;

CREATE OR REPLACE FUNCTION market.campaign_ref (
  p_campaign uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return coalesce((select jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'org_id', c.org_id)
                     from market.campaigns c where c.id = p_campaign), '{}');
end $function$;

CREATE OR REPLACE FUNCTION market.campaign_report (
  p_campaign uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
declare
  counted constant tracking.submission_status[] := array['tracking', 'flagged', 'locked', 'settled']::tracking.submission_status[];
begin
  return (
    select jsonb_build_object(
      'campaign', jsonb_build_object('title', c.title, 'status', c.status, 'start_at', c.start_at,
                                     'submit_deadline', c.submit_deadline, 'platforms', c.platforms),
      'views_valid', coalesce((select sum(s.counted_views) from tracking.submissions s
                               where s.campaign_id = c.id and s.status = any (counted)), 0),
      'clips', (select count(*) from tracking.submissions s where s.campaign_id = c.id and s.status = any (counted)),
      'clippers', (select count(distinct s.user_id) from tracking.submissions s
                   where s.campaign_id = c.id and s.status = any (counted)),
      'by_platform', coalesce((select jsonb_object_agg(x.platform, x.views)
                               from (select s.platform, sum(s.counted_views) as views from tracking.submissions s
                                     where s.campaign_id = c.id and s.status = any (counted) group by s.platform) x), '{}'::jsonb),
      'budget', coalesce((select jsonb_agg(jsonb_build_object('reward_type', rt.code, 'unit', rt.unit_label,
                                                              'total', p.total, 'spent', p.allocated))
                          from finance.reward_pools p join market.reward_types rt on rt.id = p.reward_type_id
                          where p.campaign_id = c.id), '[]'::jsonb),
      'top_clips', coalesce((select jsonb_agg(jsonb_build_object('url', t.url, 'platform', t.platform, 'views', t.counted_views))
                             from (select s.url, s.platform, s.counted_views from tracking.submissions s
                                   where s.campaign_id = c.id and s.status = any (counted)
                                   order by s.counted_views desc limit 10) t), '[]'::jsonb))
    from market.campaigns c where c.id = p_campaign);
end $function$;

CREATE OR REPLACE FUNCTION market.campaign_visible (
  p market.campaigns
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  pub boolean := p.status in ('live', 'paused', 'tracking', 'exhausted', 'settling', 'settled') and not p.is_template;
begin
  if uid is null then
    return pub and p.visibility = 'public';
  end if;
  if not ops.iss_ok() then
    return false;
  end if;
  return (pub and (p.visibility = 'public'
                   or (p.visibility = 'invite' and market.is_invited(p.id))
                   or (p.visibility = 'level' and exists (select 1 from market.profiles pr
                                                          where pr.id = uid and pr.trust_score >= p.min_trust_score))))
      or ops.is_org_member(p.org_id) or ops.has_admin();
end $function$;

CREATE OR REPLACE FUNCTION market.check_rule_params (
  p_kind text,
  p      jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  t jsonb;
  prev numeric := -1;
  i int := 0;
begin
  if jsonb_typeof(p) is distinct from 'object' then
    perform market.fail('invalid:rule_params', 'params harus object');
  end if;
  if p_kind = 'per_1k_views' then
    if coalesce(market.jnum(p -> 'rate'), 0) <= 0 then
      perform market.fail('invalid:rule_params', 'per_1k_views butuh rate > 0');
    end if;
  elsif p_kind = 'flat_per_post' then
    if coalesce(market.jnum(p -> 'amount'), 0) <= 0 then
      perform market.fail('invalid:rule_params', 'flat_per_post butuh amount > 0');
    end if;
  elsif p_kind = 'milestone_bonus' then
    if coalesce(market.jnum(p -> 'threshold'), 0) <= 0 or coalesce(market.jnum(p -> 'amount'), 0) <= 0 then
      perform market.fail('invalid:rule_params', 'milestone_bonus butuh threshold & amount > 0');
    end if;
  elsif p_kind = 'tiered_cpm' then
    if jsonb_typeof(p -> 'tiers') is distinct from 'array' or jsonb_array_length(p -> 'tiers') = 0 then
      perform market.fail('invalid:rule_params', 'tiered_cpm butuh tiers [{from, to, rate}]');
    end if;
    for t in select jsonb_array_elements(p -> 'tiers') loop
      if market.jnum(t -> 'from') is null or market.jnum(t -> 'from') <= prev or coalesce(market.jnum(t -> 'rate'), 0) <= 0
         or (i = 0 and market.jnum(t -> 'from') <> 0)
         or (t ? 'to' and jsonb_typeof(t -> 'to') <> 'null' and market.jnum(t -> 'to') <= market.jnum(t -> 'from')) then
        perform market.fail('invalid:rule_params', 'tier harus mulai dari 0, naik, rate > 0');
      end if;
      prev := market.jnum(t -> 'from');
      i := i + 1;
    end loop;
  else
    perform market.fail('invalid:rule_kind', coalesce(p_kind, 'null'));
  end if;
end $function$;

CREATE OR REPLACE FUNCTION market.claim_check (
  p_campaign uuid,
  OUT        state text,
  OUT        reason text
)
  RETURNS record
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
  c market.campaigns;
  pr market.profiles;
  acc record;
begin
  select * into c from market.campaigns where id = p_campaign;
  if uid is null or c.id is null then
    return;
  end if;
  if c.status in ('tracking', 'settling', 'settled') or c.submit_deadline <= now() then
    state := 'deadline_passed';
    return;
  end if;
  if c.status = 'exhausted'
     or not exists (select 1 from finance.reward_pools pl where pl.campaign_id = c.id and pl.allocated < pl.total) then
    state := 'budget_exhausted';
    return;
  end if;
  if exists (select 1 from market.claims cl where cl.campaign_id = c.id and cl.user_id = uid
             and cl.status = 'open' and cl.expires_at > now()) then
    state := 'claimed_not_submitted';
    return;
  end if;
  state := 'not_eligible';
  if c.status <> 'live' then
    reason := 'campaign_not_live';
    return;
  end if;
  -- Kuota = clipper berbeda yang memegang slot (claim terbuka belum lewat atau sudah submit); pemegang slot boleh claim lagi.
  if c.clipper_quota is not null
     and not exists (select 1 from market.claims cl where cl.campaign_id = c.id and cl.user_id = uid
                     and (cl.status = 'submitted' or (cl.status = 'open' and cl.expires_at > now())))
     and (select count(distinct cl.user_id) from market.claims cl where cl.campaign_id = c.id
          and (cl.status = 'submitted' or (cl.status = 'open' and cl.expires_at > now()))) >= c.clipper_quota then
    state := 'slots_full';
    return;
  end if;
  select * into pr from market.profiles where id = uid;
  if pr.id is null then
    reason := 'profile_missing';
  elsif not ((pr.status = 'active' and (pr.suspended_until is null or pr.suspended_until <= now()))
             or (pr.status = 'suspended' and pr.suspended_until <= now())) then
    reason := 'profile_inactive';
  elsif ops.org_role(c.org_id) is not null then
    reason := 'own_org';
  elsif c.visibility = 'invite' and not market.is_invited(c.id) then
    reason := 'not_invited';
  elsif pr.trust_score < c.min_trust_score then
    reason := 'min_trust_score';
  elsif c.kyc_required and coalesce((select auth.jwt() ->> 'kyc'), '') <> 'approved' then
    reason := 'kyc_required';
  end if;
  if reason is not null then
    return;
  end if;
  select count(*) as n_acc,
         count(*) filter (where coalesce(a.followers, 0) >= c.min_followers) as n_fol,
         count(*) filter (where coalesce(a.followers, 0) >= c.min_followers
                          and (c.min_account_age_days = 0
                               or a.platform_created_at <= now() - make_interval(days => c.min_account_age_days))) as n_ok
    into acc
    from tracking.social_accounts a
   where a.user_id = uid and a.status = 'verified' and a.platform = any (c.platforms);
  if acc.n_acc = 0 then
    reason := 'need_social_account:' || c.platforms[1];
  elsif acc.n_fol = 0 then
    reason := 'min_followers';
  elsif acc.n_ok = 0 then
    reason := 'min_account_age';
  elsif (select count(*) from tracking.submissions s where s.campaign_id = c.id and s.user_id = uid
         and s.status not in ('rejected', 'rejected_final')) >= c.max_clips_per_clipper then
    reason := 'max_clips';
  else
    state := 'can_claim';
  end if;
end $function$;

CREATE OR REPLACE FUNCTION market.decide_org (
  p_org      uuid,
  p_decision text,
  p_actor    uuid,
  p_reason   text,
  p_message  text,
  p_note     text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  o market.organizations;
begin
  select * into o from market.organizations where id = p_org for update;
  if o.id is null then
    perform market.fail('not_found:org', null, 'P0002');
  end if;
  if p_decision = 'approve' then
    update market.organizations set status = 'verified', verified_by = p_actor, verified_at = now() where id = o.id;
  elsif p_decision = 'reject' then
    if nullif(btrim(p_reason), '') is null then
      perform market.fail('invalid:reason', 'penolakan wajib alasan');
    end if;
    if o.status = 'verified' then
      perform market.fail('invalid_state:verified', 'org sudah verified; pakai suspend');
    end if;
  else
    perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
  end if;
  insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
  values ('org', o.id, p_actor, p_decision, p_reason, p_message, p_note);
  perform market.notify_org(o.id, null, case p_decision when 'approve' then 'org.verified' else 'org.rejected' end,
                            jsonb_build_object('reason', p_reason, 'message', p_message));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (p_actor, case p_decision when 'approve' then 'org.verify' else 'org.reject' end, 'org:' || o.id,
          jsonb_build_object('status', o.status),
          jsonb_build_object('status', case p_decision when 'approve' then 'verified' else o.status::text end, 'reason', p_reason));
end $function$;

CREATE OR REPLACE FUNCTION market.ensure_member_profile (
  p_user         uuid,
  p_username     text DEFAULT NULL::text,
  p_display_name text DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uname text := lower(btrim(p_username));
begin
  if exists (select 1 from market.profiles p where p.id = p_user) then
    return;
  end if;
  if uname is null or uname !~ '^[a-z0-9_.]{3,30}$' or exists (select 1 from market.profiles p where p.username = uname) then
    uname := 'm_' || substr(replace(p_user::text, '-', ''), 1, 12);
  end if;
  while exists (select 1 from market.profiles p where p.username = uname) loop
    uname := 'm_' || substr(md5(random()::text), 1, 12);
  end loop;
  insert into market.profiles (id, username, display_name)
  values (p_user, uname, coalesce(nullif(left(btrim(p_display_name), 50), ''), 'Anggota brand'));
end $function$;

CREATE OR REPLACE FUNCTION market.fail (
  p_code    text,
  p_detail  text DEFAULT NULL::text,
  p_errcode text DEFAULT 'P0001'::text
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  raise exception using message = p_code, errcode = p_errcode, detail = coalesce(p_detail, '');
end $function$;

CREATE OR REPLACE FUNCTION market.freeze_brief()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if old.status not in ('draft', 'rejected')
     and (new.slug, new.type, new.platforms, new.brief, new.required_hashtags, new.required_mentions, new.required_links,
          new.sponsored_label, new.min_duration_sec, new.max_duration_sec, new.dos, new.donts, new.example_urls)
         is distinct from
         (old.slug, old.type, old.platforms, old.brief, old.required_hashtags, old.required_mentions, old.required_links,
          old.sponsored_label, old.min_duration_sec, old.max_duration_sec, old.dos, old.donts, old.example_urls) then
    raise exception 'campaigns: brief terkunci sejak diajukan (status %); yang boleh diubah hanya FAQ', old.status
      using errcode = '23514';
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION market.is_direct_member (
  p_org    uuid,
  p_user   uuid,
  VARIADIC p_roles market.org_role[] DEFAULT '{}'::market.org_role[]
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return exists (select 1 from market.org_members m where m.org_id = p_org and m.user_id = p_user
                 and (cardinality(p_roles) = 0 or m.role = any (p_roles)));
end $function$;

CREATE OR REPLACE FUNCTION market.is_invited (
  p_campaign uuid
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return exists (select 1 from market.campaign_invites i where i.campaign_id = p_campaign and i.user_id = (select auth.uid()));
end $function$;

CREATE OR REPLACE FUNCTION market.jnum (
  p jsonb
)
  RETURNS numeric
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  select case when jsonb_typeof(p) = 'number' then (p #>> '{}')::numeric
              when jsonb_typeof(p) = 'string' and (p #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' then (p #>> '{}')::numeric end;
$function$;

CREATE OR REPLACE FUNCTION market.keep_one_owner()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if old.role = 'brand_owner' and (tg_op = 'DELETE' or new.role <> 'brand_owner')
     and not exists (select 1 from market.org_members m
                     where m.org_id = old.org_id and m.role = 'brand_owner' and m.user_id <> old.user_id) then
    raise exception 'org harus punya minimal satu brand_owner' using errcode = '23514';
  end if;
  return coalesce(new, old);
end $function$;

CREATE OR REPLACE FUNCTION market.norm_list (
  p       jsonb,
  p_kind  text,
  p_field text
)
  RETURNS text[]
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  res text[] := '{}';
  x text;
  v text;
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return res;
  end if;
  if jsonb_typeof(p) <> 'array' then
    perform market.fail('invalid:' || p_field, 'harus array');
  end if;
  for x in select jsonb_array_elements_text(p) loop
    v := btrim(x);
    if p_kind = 'hashtag' then
      v := lower(ltrim(v, '#'));
      if v <> '' and v !~ '^[[:lower:][:digit:]_]+$' then
        perform market.fail('invalid:' || p_field, format('hashtag "%s" hanya boleh huruf, angka, _', x));
      end if;
    elsif p_kind = 'mention' then
      v := lower(ltrim(v, '@'));
      if v <> '' and v !~ '^[[:lower:][:digit:]_.]+$' then
        perform market.fail('invalid:' || p_field, format('mention "%s" hanya boleh huruf, angka, _ dan .', x));
      end if;
    elsif p_kind = 'link' and v <> '' then
      if v !~* '^[a-z][a-z0-9+.-]*://' then
        v := 'https://' || v;
      end if;
      if v !~ '^https://\S+$' then
        perform market.fail('invalid:' || p_field, format('link "%s" wajib https', x));
      end if;
    end if;
    if v <> '' and not (v = any (res)) then
      res := res || v;
    end if;
  end loop;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION market.notify_org (
  p_org     uuid,
  p_roles   market.org_role[],
  p_event   text,
  p_payload jsonb             DEFAULT '{}'::jsonb
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r record;
  n int := 0;
  body jsonb := coalesce(p_payload, '{}')
                || jsonb_build_object('org_id', p_org, 'org_name', (select o.name from market.organizations o where o.id = p_org));
begin
  for r in
    select m.user_id from market.org_members m
     where m.org_id = p_org and (coalesce(cardinality(p_roles), 0) = 0 or m.role = any (p_roles))
    union
    select m.user_id from market.org_links l join market.org_members m on m.org_id = l.agency_org_id
     where l.client_org_id = p_org and l.approved_at is not null and l.revoked_at is null
       and (coalesce(cardinality(p_roles), 0) = 0 or m.role = any (p_roles))
  loop
    perform ops.enqueue_notification(r.user_id, p_event, body);
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION market.refresh_leaderboard()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  refresh materialized view concurrently market.leaderboard_weekly;
  refresh materialized view concurrently market.leaderboard_campaign;
end $function$;

CREATE OR REPLACE FUNCTION market.rule_rate (
  p_kind   text,
  p_params jsonb
)
  RETURNS numeric
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  select case p_kind when 'per_1k_views' then (p_params ->> 'rate')::numeric
                     when 'tiered_cpm' then (p_params -> 'tiers' -> 0 ->> 'rate')::numeric end;
$function$;

CREATE OR REPLACE FUNCTION market.run_budget_alerts()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  c record;
  pj jsonb;
  util numeric;
  th int;
  top int;
  n int := 0;
  roles constant market.org_role[] := array['brand_owner', 'brand_manager']::market.org_role[];
begin
  for c in select x.id, x.org_id, x.title, x.status from market.campaigns x
            where x.status in ('live', 'paused', 'tracking', 'exhausted') loop
    pj := market.campaign_projection(c.id);
    util := (pj ->> 'utilization_pct')::numeric;
    if util is null then
      continue;
    end if;
    top := null;
    foreach th in array array[50, 80, 100] loop
      if util >= th then
        insert into market.budget_alerts (campaign_id, kind, utilization_pct) values (c.id, 'used_' || th, util)
        on conflict do nothing;
        if found then
          top := th;
        end if;
      end if;
    end loop;
    if top is not null then
      n := n + market.notify_org(c.org_id, roles, 'budget.used',
                                 jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'pct', top, 'utilization_pct', util));
    end if;
    if c.status = 'live' and (pj ->> 'elapsed_days')::numeric >= 2 and (pj ->> 'projected_utilization_pct')::numeric < 50 then
      insert into market.budget_alerts (campaign_id, kind, utilization_pct) values (c.id, 'projection_low', util)
      on conflict do nothing;
      if found then
        n := n + market.notify_org(c.org_id, roles, 'budget.projection_low',
                                   jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title,
                                                      'projected_utilization_pct', pj -> 'projected_utilization_pct',
                                                      'suggestions', jsonb_build_array('raise_rate', 'extend', 'invite', 'pin')));
      end if;
    end if;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION market.run_claim_expiry()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  c record;
begin
  for c in update market.claims set reminded_at = now()
            where status = 'open' and reminded_at is null and expires_at <= now() + interval '6 hours' and expires_at > now()
            returning id, user_id, campaign_id, expires_at loop
    perform ops.enqueue_notification(c.user_id, 'claim.expiring',
                                     jsonb_build_object('claim_id', c.id, 'campaign_id', c.campaign_id, 'expires_at', c.expires_at));
  end loop;
  update market.claims set status = 'expired' where status = 'open' and expires_at <= now();
end $function$;

CREATE OR REPLACE FUNCTION market.run_lifecycle()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  grace interval := (ops.cfg('tracking.final_grace_hours', '72'))::numeric * interval '1 hour';
  active constant tracking.submission_status[] := array['validating', 'in_review', 'tracking', 'flagged', 'appealed']::tracking.submission_status[];
  r record;
  fin bigint;
  n int;
begin
  for r in update market.campaigns set status = 'live' where status = 'scheduled' and start_at <= now() returning id, org_id loop
    perform market.notify_org(r.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'campaign.live',
                              market.campaign_ref(r.id));
    perform market.announce_campaign(r.id);
  end loop;
  update market.campaigns set status = 'tracking' where status in ('live', 'paused') and submit_deadline <= now();

  perform finance.finalize_settlements();

  for r in select s.id, s.posted_at + make_interval(days => c.view_window_days) as window_end, s.next_poll_at
             from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
            where s.status = 'tracking'
              and (s.posted_at + make_interval(days => c.view_window_days) <= now() or c.status in ('exhausted', 'settling', 'settled'))
            order by s.id
            for update of s skip locked loop
    select v.id into fin from tracking.view_snapshots v where v.submission_id = r.id and v.is_final;
    if fin is not null then
      perform finance.accrue_earnings(r.id, fin);
      update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id and status = 'tracking';
    elsif r.window_end + grace <= now() then
      update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id;
      perform ops.raise_alert('tracking.final_missing', 'warning', jsonb_build_object('submission_id', r.id));
    elsif r.next_poll_at > now() + interval '1 hour' then
      update tracking.submissions set next_poll_at = now() where id = r.id;
    end if;
  end loop;

  update market.campaigns c set status = 'settling'
   where c.status in ('tracking', 'exhausted')
     and not exists (select 1 from tracking.submissions s where s.campaign_id = c.id and s.status = any (active))
     and not exists (select 1 from finance.pool_settlements ps join finance.reward_pools rp on rp.id = ps.pool_id
                     where rp.campaign_id = c.id);
  for r in update market.campaigns c set status = 'settled'
            where c.status = 'settling'
              and not exists (select 1 from tracking.submissions s where s.campaign_id = c.id
                              and (s.status = any (active) or s.status = 'locked'))
            returning c.id, c.org_id loop
    perform market.notify_org(r.org_id, array['brand_owner', 'brand_manager', 'brand_finance']::market.org_role[], 'campaign.settled',
      market.campaign_ref(r.id) || jsonb_build_object('leftover',
        coalesce((select jsonb_agg(finance.amount_ref(rp.reward_type_id, finance.balance(finance.account('campaign_pool', rp.id, rp.reward_type_id)))
                                   || jsonb_build_object('pool_id', rp.id) order by rp.id)
                  from finance.reward_pools rp where rp.campaign_id = r.id), '[]')));
  end loop;

  -- Kesehatan job tracking (F-A01): submisi terlambat > 2 jam dari jadwal poll → alert (maks satu per 6 jam).
  select count(*) into n from tracking.submissions s
   where s.status in ('tracking', 'flagged') and s.next_poll_at < now() - interval '2 hours';
  if n > 0 then
    perform ops.raise_alert('tracking.lag', 'warning', jsonb_build_object('overdue', n), interval '6 hours');
  end if;

  perform finance.retry_instant_payouts();
  perform trust.auto_approve_overdue();
end $function$;

CREATE OR REPLACE FUNCTION market.session_uid()
  RETURNS uuid
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null or not ops.iss_ok() then
    perform market.fail('auth:no_session', 'butuh sesi identity', '42501');
  end if;
  return uid;
end $function$;

CREATE OR REPLACE FUNCTION ops.cfg (
  p_key     text,
  p_default jsonb DEFAULT NULL::jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return coalesce((select s.value from ops.settings s where s.key = p_key), p_default);
end $function$;

CREATE OR REPLACE FUNCTION ops.check_transition()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  machine text := tg_argv[0];
  initial text := tg_argv[1];
  allowed jsonb := tg_argv[2]::jsonb;
begin
  if tg_op = 'INSERT' then
    if new.status::text <> initial then
      raise exception '% (%): status awal harus %', tg_table_name, machine, initial using errcode = '23514';
    end if;
  elsif new.status is distinct from old.status then
    if not coalesce((allowed -> (old.status::text)) ? (new.status::text), false) then
      raise exception '% (%): transisi % → % tidak diizinkan', tg_table_name, machine, old.status, new.status
        using errcode = '23514';
    end if;
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION ops.dispatch_broadcasts()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  b ops.broadcasts;
  seg jsonb;
  r record;
  n int;
  total int := 0;
begin
  for b in select * from ops.broadcasts where sent_at is null and scheduled_at <= now()
            order by scheduled_at for update skip locked loop
    seg := b.segment;
    n := 0;
    for r in
      select p.id from market.profiles p
       where p.status = 'active'
         and (not seg ? 'platforms'
              or exists (select 1 from tracking.social_accounts a where a.user_id = p.id and a.status = 'verified'
                         and a.platform::text in (select jsonb_array_elements_text(seg -> 'platforms'))))
         and (not seg ? 'min_trust_score' or p.trust_score >= (seg ->> 'min_trust_score')::int)
         and (not seg ? 'max_trust_score' or p.trust_score <= (seg ->> 'max_trust_score')::int)
         and (not seg ? 'kyc'
              or (seg ->> 'kyc' = 'approved') = coalesce((select d.decision = 'approve' from trust.review_decisions d
                                                          where d.target_type = 'kyc' and d.target_id = p.id
                                                          order by d.created_at desc, d.id desc limit 1), false))
         and (not seg ? 'active_days'
              or exists (select 1 from market.claims cl where cl.user_id = p.id
                         and cl.created_at >= now() - make_interval(days => (seg ->> 'active_days')::int))
              or exists (select 1 from tracking.submissions s where s.user_id = p.id
                         and s.created_at >= now() - make_interval(days => (seg ->> 'active_days')::int)))
    loop
      perform ops.enqueue_notification(r.id, 'broadcast.sent',
                                       jsonb_build_object('broadcast_id', b.id, 'title', b.title, 'body', b.body,
                                                          'channels', to_jsonb(b.channels)),
                                       'email' = any (b.channels) or 'push' = any (b.channels));
      n := n + 1;
    end loop;
    update ops.broadcasts set sent_at = now(), recipient_count = n where id = b.id;
    total := total + n;
  end loop;
  return total;
end $function$;

CREATE OR REPLACE FUNCTION ops.enqueue_notification (
  p_user    uuid,
  p_event   text,
  p_payload jsonb   DEFAULT '{}'::jsonb,
  p_email   boolean DEFAULT true
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  nid bigint;
  promo boolean := p_event in ('campaign.new', 'broadcast.sent');
begin
  insert into ops.notifications (user_id, event, payload) values (p_user, p_event, p_payload) returning id into nid;
  if p_email and (not promo or coalesce((select np.email_promotions from ops.notification_prefs np
                                          where np.user_id = p_user), true)) then
    perform pgmq.send('email', jsonb_build_object('notification_id', nid, 'user_id', p_user, 'event', p_event,
                                                  'promo', promo));
  end if;
  return nid;
end $function$;

CREATE OR REPLACE FUNCTION ops.has_admin (
  VARIADIC roles text[] DEFAULT '{}'::text[]
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return ops.iss_ok()
     and coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists (select 1 from jsonb_array_elements_text(coalesce((select auth.jwt() -> 'app_roles'), '[]'::jsonb)) r(role)
                 where r.role = 'admin_super' or (cardinality(roles) = 0 and r.role like 'admin\_%') or r.role = any (roles));
end $function$;

CREATE OR REPLACE FUNCTION ops.invoke_function (
  p_name text,
  p_body jsonb DEFAULT '{}'::jsonb
)
  RETURNS bigint
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select net.http_post(
    url := (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'core_url') || '/functions/v1/' || p_name,
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'apikey', (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'core_secret_key')));
$function$;

CREATE OR REPLACE FUNCTION ops.is_org_member (
  p_org    uuid,
  VARIADIC roles market.org_role[] DEFAULT '{}'::market.org_role[]
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r text := ops.org_role(p_org)::text;
begin
  return r is not null and (cardinality(roles) = 0 or r = any (roles::text[]));
end $function$;

CREATE OR REPLACE FUNCTION ops.iss_ok()
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return coalesce((select auth.jwt() ->> 'iss')
                  = (select s.value #>> '{}' from ops.settings s where s.key = 'auth.identity_issuer'), false);
end $function$;

CREATE OR REPLACE FUNCTION ops.org_role (
  p_org uuid
)
  RETURNS market.org_role
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return coalesce(
    (select m.role from market.org_members m where m.org_id = p_org and m.user_id = (select auth.uid())),
    (select m.role from market.org_links l join market.org_members m on m.org_id = l.agency_org_id
      where l.client_org_id = p_org and l.approved_at is not null and l.revoked_at is null and m.user_id = (select auth.uid())
      order by array_position(enum_range(null::market.org_role), m.role) limit 1));
end $function$;

CREATE OR REPLACE FUNCTION ops.raise_alert (
  p_kind     text,
  p_severity text,
  p_payload  jsonb,
  p_dedupe   interval DEFAULT NULL::interval
)
  RETURNS bigint
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  aid bigint;
begin
  if p_dedupe is not null and exists (select 1 from ops.alerts a where a.kind = p_kind and a.resolved_at is null
                                        and a.created_at > now() - p_dedupe) then
    return null;
  end if;
  insert into ops.alerts (kind, severity, payload) values (p_kind, p_severity, coalesce(p_payload, '{}')) returning id into aid;
  return aid;
end $function$;

CREATE OR REPLACE FUNCTION ops.reject_mutation()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  raise exception '% hanya boleh ditambah (append-only)', tg_table_name using errcode = '42501';
end $function$;

CREATE OR REPLACE FUNCTION tracking.check_account_limit()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  n int;
  max_n int := coalesce((select (s.value #>> '{}')::int from ops.settings s
                         where s.key = 'public.market.max_accounts_per_platform'), 3);
begin
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text || ':' || new.platform::text, 0));
  select count(*) into n from tracking.social_accounts a
   where a.user_id = new.user_id and a.platform = new.platform and a.status <> 'disconnected' and a.id <> new.id;
  if n >= max_n then
    raise exception 'maksimal % akun % per clipper', max_n, new.platform using errcode = '23514';
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION tracking.enqueue_due_submissions (
  p_limit integer DEFAULT 500
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  n int := 0;
  s record;
begin
  for s in update tracking.submissions t set next_poll_at = now() + interval '1 hour'
            where t.id in (select d.id from tracking.submissions d
                           where d.status in ('tracking', 'flagged') and d.next_poll_at <= now()
                           order by d.next_poll_at limit p_limit for update skip locked)
            returning t.id, t.platform loop
    perform pgmq.send('tracking', jsonb_build_object('submission_id', s.id, 'platform', s.platform));
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION tracking.final_due (
  p_submission uuid
)
  RETURNS boolean
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  return exists (select 1 from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
                 where s.id = p_submission
                   and (s.posted_at + make_interval(days => c.view_window_days) <= now()
                        or c.status in ('exhausted', 'settling', 'settled')))
     and not exists (select 1 from tracking.view_snapshots v where v.submission_id = p_submission and v.is_final);
end $function$;

CREATE OR REPLACE FUNCTION trust.apply_submission_decision (
  p_submission uuid,
  p_decision   text,
  p_actor      uuid,
  p_reason     text,
  p_message    text,
  p_note       text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  d jsonb := coalesce((select st.value from ops.settings st where st.key = 'trust.score_deltas'), '{}');
  d_ok int := coalesce((d ->> 'submission_approved')::int, 1);
  d_rej int := coalesce((d ->> 'submission_rejected')::int, -2);
  d_app int := coalesce((d ->> 'appeal_failed')::int, -3);
  to_status tracking.submission_status;
  logged text;
  delta int;
  score_reason text;
begin
  select * into s from tracking.submissions where id = p_submission for update;
  if s.id is null then
    perform market.fail('not_found:submission', null, 'P0002');
  end if;
  if s.status = 'in_review' and p_decision in ('approve', 'auto_approve') then
    to_status := 'tracking'; logged := p_decision; delta := d_ok; score_reason := 'submission_approved';
  elsif s.status = 'in_review' and p_decision = 'reject' then
    to_status := 'rejected'; logged := 'reject'; delta := d_rej; score_reason := 'submission_rejected';
  elsif s.status = 'appealed' and p_decision in ('overturn', 'approve') then
    -- banding diterima: hapus efek reject sebelumnya + bonus approve
    to_status := 'tracking'; logged := 'overturn'; delta := d_ok - d_rej; score_reason := 'submission_approved';
  elsif s.status = 'appealed' and p_decision in ('uphold', 'reject') then
    to_status := 'rejected_final'; logged := 'uphold'; delta := d_app; score_reason := 'appeal_failed';
  else
    perform market.fail('invalid_state:' || s.status, format('keputusan %s tidak berlaku untuk submisi %s', p_decision, s.status));
  end if;
  if to_status in ('rejected', 'rejected_final') and nullif(btrim(p_reason), '') is null then
    perform market.fail('invalid:reason', 'penolakan wajib alasan standar');
  end if;

  update tracking.submissions
     set status = to_status, next_poll_at = case when to_status = 'tracking' then now() else next_poll_at end
   where id = s.id;
  insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
  values ('submission', s.id, p_actor, logged, p_reason, p_message, p_note);
  if delta <> 0 then
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by)
    values (s.user_id, greatest(least(delta, 100), -100), score_reason, s.id::text, p_actor);
  end if;
  perform ops.enqueue_notification(s.user_id, case when to_status = 'tracking' then 'submission.approved' else 'submission.rejected' end,
                                   jsonb_build_object('submission_id', s.id, 'campaign_id', s.campaign_id,
                                                      'campaign_title', (select c.title from market.campaigns c where c.id = s.campaign_id),
                                                      'url', s.url, 'reason', p_reason,
                                                      'message', p_message, 'final', to_status = 'rejected_final'));
end $function$;

CREATE OR REPLACE FUNCTION trust.auto_approve_overdue()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  h int := coalesce((select (st.value #>> '{}')::int from ops.settings st where st.key = 'market.brand_review_auto_approve_hours'), 72);
  r record;
  n int := 0;
begin
  for r in select s.id from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
            where s.status = 'in_review' and c.review_mode = 'brand' and s.created_at <= now() - make_interval(hours => h)
            order by s.created_at
            for update of s skip locked loop
    perform trust.apply_submission_decision(r.id, 'auto_approve', null, null, null, 'auto');
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION trust.raise_flag (
  p_target_type text,
  p_target_id   uuid,
  p_signal      text,
  p_score       numeric,
  p_details     jsonb,
  p_status      text    DEFAULT 'open'::text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  fid uuid;
  n int;
begin
  if p_status in ('open', 'held') then
    insert into trust.fraud_flags (target_type, target_id, signal, score, status, details)
    values (p_target_type, p_target_id, p_signal, p_score, p_status, coalesce(p_details, '{}'))
    on conflict (target_type, target_id, signal) where status in ('open', 'held') do nothing
    returning id into fid;
  else
    insert into trust.fraud_flags (target_type, target_id, signal, score, status, details, resolved_at)
    values (p_target_type, p_target_id, p_signal, p_score, p_status, coalesce(p_details, '{}'), now())
    returning id into fid;
  end if;
  if fid is not null then
    select count(*) into n from trust.fraud_flags f where f.created_at > now() - interval '1 hour';
    if n > (ops.cfg('trust.fraud.flag_spike_per_hour', '20'))::int then
      perform ops.raise_alert('fraud.flag_spike', 'warning', jsonb_build_object('flags_last_hour', n), interval '1 hour');
    end if;
  end if;
  return fid;
end $function$;

CREATE OR REPLACE FUNCTION trust.recalc_scores()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  n int;
begin
  update market.profiles p set trust_score = x.score
    from (select pr.id, least(100, greatest(0, 50 + coalesce(sum(e.delta), 0)))::smallint as score
            from market.profiles pr left join trust.score_events e on e.user_id = pr.id
           group by pr.id) x
   where x.id = p.id and p.trust_score <> x.score;
  get diagnostics n = row_count;
  return n;
end $function$;

ALTER TABLE "finance"."fulfillments"
  ADD CONSTRAINT "fulfillments_delivered_complete" CHECK (((status <> 'delivered'::finance.fulfillment_status) OR (delivered_at IS NOT NULL)));

ALTER TABLE "finance"."ledger_entries"
  ADD CONSTRAINT "ledger_entries_account_fk" FOREIGN KEY (account_id, reward_type_id) REFERENCES finance.ledger_accounts(id, reward_type_id);

ALTER TABLE "finance"."ledger_entries"
  ADD CONSTRAINT "ledger_entries_idempotent" UNIQUE NULLS NOT DISTINCT (ref_type, ref_id, account_id, state);

ALTER TABLE "finance"."payouts"
  ADD CONSTRAINT "payouts_batch_id_fkey" FOREIGN KEY (batch_id) REFERENCES finance.payout_batches(id);

ALTER TABLE "finance"."payouts"
  ADD CONSTRAINT "payouts_hold_has_reason" CHECK (((status <> 'on_hold'::finance.payout_status) OR (hold_reason IS NOT NULL)));

ALTER TABLE "finance"."payouts"
  ADD CONSTRAINT "payouts_paid_complete" CHECK (((status <> 'paid'::finance.payout_status) OR ((paid_at IS NOT NULL) AND (((channel = 'batch'::text) AND (batch_id IS
    NOT NULL)) OR ((channel = 'instant'::text) AND (provider_ref IS NOT NULL))))));

ALTER TABLE "finance"."reward_codes"
  ADD CONSTRAINT "reward_codes_fulfillment_id_fkey" FOREIGN KEY (fulfillment_id) REFERENCES finance.fulfillments(id);

ALTER TABLE "finance"."clip_earnings"
  ADD CONSTRAINT "clip_earnings_pool_id_fkey" FOREIGN KEY (pool_id) REFERENCES finance.reward_pools(id);

ALTER TABLE "finance"."pool_settlements"
  ADD CONSTRAINT "pool_settlements_pool_id_fkey" FOREIGN KEY (pool_id) REFERENCES finance.reward_pools(id) ON DELETE CASCADE;

ALTER TABLE "market"."campaigns"
  ADD CONSTRAINT "campaigns_fee_rule_id_fkey" FOREIGN KEY (fee_rule_id) REFERENCES finance.fee_rules(id);

ALTER TABLE "finance"."invoices"
  ADD CONSTRAINT "invoices_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES market.campaigns(id);

ALTER TABLE "finance"."org_refunds"
  ADD CONSTRAINT "org_refunds_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES market.campaigns(id);

ALTER TABLE "finance"."reward_pools"
  ADD CONSTRAINT "reward_pools_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES market.campaigns(id) ON DELETE CASCADE;

ALTER TABLE "market"."budget_alerts"
  ADD CONSTRAINT "budget_alerts_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES market.campaigns(id) ON DELETE CASCADE;

ALTER TABLE "market"."campaign_assets"
  ADD CONSTRAINT "campaign_assets_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES market.campaigns(id) ON DELETE CASCADE;

ALTER TABLE "market"."campaign_invites"
  ADD CONSTRAINT "campaign_invites_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES market.campaigns(id) ON DELETE CASCADE;

ALTER TABLE "market"."campaigns"
  ADD CONSTRAINT "campaigns_platforms_check" CHECK ((cardinality(platforms) >= 1));

ALTER TABLE "market"."campaigns"
  ADD CONSTRAINT "campaigns_scheduled_has_dates"
    CHECK
    (((status = ANY (ARRAY['draft'::market.campaign_status, 'in_review'::market.campaign_status, 'rejected'::market.campaign_status, 'cancelled'::market.campaign_status])) OR
    ((start_at IS NOT NULL) AND (submit_deadline IS NOT NULL))));

ALTER TABLE "market"."campaigns"
  ADD CONSTRAINT "campaigns_template_stays_draft" CHECK (((NOT is_template) OR (status = 'draft'::market.campaign_status)));

ALTER TABLE "market"."campaigns"
  ADD CONSTRAINT "campaigns_category_id_fkey" FOREIGN KEY (category_id) REFERENCES market.categories(id);

ALTER TABLE "market"."claims"
  ADD CONSTRAINT "claims_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES market.campaigns(id);

ALTER TABLE "market"."organizations"
  ADD CONSTRAINT "organizations_fee_rule_id_fkey" FOREIGN KEY (fee_rule_id) REFERENCES finance.fee_rules(id);

ALTER TABLE "finance"."invoices"
  ADD CONSTRAINT "invoices_org_id_fkey" FOREIGN KEY (org_id) REFERENCES market.organizations(id);

ALTER TABLE "finance"."org_refunds"
  ADD CONSTRAINT "org_refunds_org_id_fkey" FOREIGN KEY (org_id) REFERENCES market.organizations(id);

ALTER TABLE "market"."campaigns"
  ADD CONSTRAINT "campaigns_org_id_fkey" FOREIGN KEY (org_id) REFERENCES market.organizations(id);

ALTER TABLE "market"."org_invites"
  ADD CONSTRAINT "org_invites_org_id_fkey" FOREIGN KEY (org_id) REFERENCES market.organizations(id);

ALTER TABLE "market"."org_links"
  ADD CONSTRAINT "org_links_agency_org_id_fkey" FOREIGN KEY (agency_org_id) REFERENCES market.organizations(id);

ALTER TABLE "market"."org_links"
  ADD CONSTRAINT "org_links_client_org_id_fkey" FOREIGN KEY (client_org_id) REFERENCES market.organizations(id);

ALTER TABLE "market"."org_members"
  ADD CONSTRAINT "org_members_org_id_fkey" FOREIGN KEY (org_id) REFERENCES market.organizations(id);

ALTER TABLE "market"."organizations"
  ADD CONSTRAINT "organizations_verified_complete" CHECK (((status <> 'verified'::market.org_status) OR ((verified_at IS NOT NULL) AND (verified_by IS NOT NULL))));

ALTER TABLE "finance"."fulfillments"
  ADD CONSTRAINT "fulfillments_user_id_fkey" FOREIGN KEY (user_id) REFERENCES market.profiles(id);

ALTER TABLE "finance"."payouts"
  ADD CONSTRAINT "payouts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES market.profiles(id);

ALTER TABLE "market"."campaign_invites"
  ADD CONSTRAINT "campaign_invites_user_id_fkey" FOREIGN KEY (user_id) REFERENCES market.profiles(id);

ALTER TABLE "market"."claims"
  ADD CONSTRAINT "claims_user_id_fkey" FOREIGN KEY (user_id) REFERENCES market.profiles(id);

ALTER TABLE "market"."org_invites"
  ADD CONSTRAINT "org_invites_accepted_by_fkey" FOREIGN KEY (accepted_by) REFERENCES market.profiles(id);

ALTER TABLE "market"."org_invites"
  ADD CONSTRAINT "org_invites_created_by_fkey" FOREIGN KEY (created_by) REFERENCES market.profiles(id);

ALTER TABLE "market"."org_members"
  ADD CONSTRAINT "org_members_user_id_fkey" FOREIGN KEY (user_id) REFERENCES market.profiles(id);

ALTER TABLE "market"."profiles"
  ADD CONSTRAINT "profiles_suspend_has_until" CHECK (((status <> 'suspended'::market.profile_status) OR (suspended_until IS NOT NULL)));

ALTER TABLE "market"."rate_rules"
  ADD CONSTRAINT "rate_rules_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES market.campaigns(id) ON DELETE CASCADE;

ALTER TABLE "finance"."clip_earnings"
  ADD CONSTRAINT "clip_earnings_rule_id_fkey" FOREIGN KEY (rule_id) REFERENCES market.rate_rules(id);

ALTER TABLE "market"."rate_rules"
  ADD CONSTRAINT "rate_rules_pool_match" FOREIGN KEY (pool_id, campaign_id, reward_type_id) REFERENCES finance.reward_pools(id, campaign_id, reward_type_id);

ALTER TABLE "market"."referrals"
  ADD CONSTRAINT "referrals_referred_id_fkey" FOREIGN KEY (referred_id) REFERENCES market.profiles(id);

ALTER TABLE "market"."referrals"
  ADD CONSTRAINT "referrals_referrer_id_fkey" FOREIGN KEY (referrer_id) REFERENCES market.profiles(id);

ALTER TABLE "market"."report_links"
  ADD CONSTRAINT "report_links_campaign_id_fkey" FOREIGN KEY (campaign_id) REFERENCES market.campaigns(id);

ALTER TABLE "market"."report_links"
  ADD CONSTRAINT "report_links_created_by_fkey" FOREIGN KEY (created_by) REFERENCES market.profiles(id);

ALTER TABLE "market"."reward_types"
  ADD CONSTRAINT "reward_types_owner_org_id_fkey" FOREIGN KEY (owner_org_id) REFERENCES market.organizations(id);

ALTER TABLE "finance"."fulfillments"
  ADD CONSTRAINT "fulfillments_reward_type_id_fkey" FOREIGN KEY (reward_type_id) REFERENCES market.reward_types(id);

ALTER TABLE "finance"."ledger_accounts"
  ADD CONSTRAINT "ledger_accounts_reward_type_id_fkey" FOREIGN KEY (reward_type_id) REFERENCES market.reward_types(id);

ALTER TABLE "finance"."reward_codes"
  ADD CONSTRAINT "reward_codes_reward_type_id_fkey" FOREIGN KEY (reward_type_id) REFERENCES market.reward_types(id);

ALTER TABLE "finance"."reward_pools"
  ADD CONSTRAINT "reward_pools_reward_type_id_fkey" FOREIGN KEY (reward_type_id) REFERENCES market.reward_types(id);

ALTER TABLE "market"."rate_rules"
  ADD CONSTRAINT "rate_rules_reward_type_id_fkey" FOREIGN KEY (reward_type_id) REFERENCES market.reward_types(id);

ALTER TABLE "ops"."notification_prefs"
  ADD CONSTRAINT "notification_prefs_user_id_fkey" FOREIGN KEY (user_id) REFERENCES market.profiles(id);

ALTER TABLE "ops"."notifications"
  ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY (user_id) REFERENCES market.profiles(id);

ALTER TABLE "tracking"."social_accounts"
  ADD CONSTRAINT "social_accounts_key" UNIQUE (id, user_id, platform);

ALTER TABLE "tracking"."social_accounts"
  ADD CONSTRAINT "social_accounts_one_owner" UNIQUE (platform, external_id);

ALTER TABLE "tracking"."social_accounts"
  ADD CONSTRAINT "social_accounts_user_id_fkey" FOREIGN KEY (user_id) REFERENCES market.profiles(id);

ALTER TABLE "tracking"."submissions"
  ADD CONSTRAINT "submissions_account_fk" FOREIGN KEY (social_account_id, user_id, platform) REFERENCES tracking.social_accounts(id, user_id, platform);

ALTER TABLE "tracking"."submissions"
  ADD CONSTRAINT "submissions_claim_fk" FOREIGN KEY (claim_id, user_id, campaign_id) REFERENCES market.claims(id, user_id, campaign_id);

ALTER TABLE "tracking"."submissions"
  ADD CONSTRAINT "submissions_locked_has_time" CHECK (((status <> ALL (ARRAY['locked'::tracking.submission_status, 'settled'::tracking.submission_status])) OR (locked_at IS
    NOT NULL)));

ALTER TABLE "tracking"."submissions"
  ADD CONSTRAINT "submissions_one_post_per_campaign" UNIQUE (campaign_id, platform, post_id);

ALTER TABLE "finance"."clip_earnings"
  ADD CONSTRAINT "clip_earnings_submission_id_fkey" FOREIGN KEY (submission_id) REFERENCES tracking.submissions(id);

ALTER TABLE "finance"."clip_earnings"
  ADD CONSTRAINT "clip_earnings_demand_snapshot_fkey" FOREIGN KEY (demand_snapshot) REFERENCES tracking.view_snapshots(id);

ALTER TABLE "tracking"."view_snapshots"
  ADD CONSTRAINT "view_snapshots_submission_id_fkey" FOREIGN KEY (submission_id) REFERENCES tracking.submissions(id);

ALTER TABLE "trust"."score_events"
  ADD CONSTRAINT "score_events_user_id_fkey" FOREIGN KEY (user_id) REFERENCES market.profiles(id);

CREATE VIEW "api"."alerts" WITH (security_invoker=true) AS  SELECT id,
    kind,
    severity,
    payload,
    created_at,
    resolved_at,
    resolved_by
   FROM ops.alerts;

CREATE VIEW "api"."audit_logs" WITH (security_invoker=true) AS  SELECT id,
    actor_id,
    action,
    target,
    before,
    after,
    at
   FROM ops.audit_logs;

CREATE VIEW "api"."broadcasts" WITH (security_invoker=true) AS  SELECT id,
    title,
    body,
    segment,
    channels,
    created_by,
    scheduled_at,
    sent_at,
    recipient_count
   FROM ops.broadcasts;

CREATE VIEW "api"."budget_alerts" WITH (security_invoker=true) AS  SELECT campaign_id,
    kind,
    utilization_pct,
    created_at
   FROM market.budget_alerts;

CREATE VIEW "api"."campaign_assets" WITH (security_invoker=true) AS  SELECT id,
    campaign_id,
    kind,
    storage_path,
    url,
    size_bytes,
    audience,
    created_at
   FROM market.campaign_assets;

CREATE VIEW "api"."campaign_invites" WITH (security_invoker=true) AS  SELECT campaign_id,
    user_id,
    invited_by,
    created_at
   FROM market.campaign_invites;

CREATE VIEW "api"."campaigns" WITH (security_invoker=true) AS  SELECT id,
    org_id,
    slug,
    title,
    type,
    category_id,
    status,
    platforms,
    brief,
    required_hashtags,
    required_mentions,
    required_links,
    sponsored_label,
    min_duration_sec,
    max_duration_sec,
    dos,
    donts,
    example_urls,
    faq,
    service_mode,
    start_at,
    submit_deadline,
    view_window_days,
    review_mode,
    min_followers,
    min_account_age_days,
    min_trust_score,
    kyc_required,
    min_views,
    max_clips_per_clipper,
    clipper_quota,
    allow_video_reuse,
    visibility,
    is_template,
    pinned_until,
    pinned_rank,
    created_at
   FROM market.campaigns;

CREATE VIEW "api"."categories" WITH (security_invoker=true) AS  SELECT id,
    name_id,
    name_en,
    sort,
    active
   FROM market.categories;

CREATE VIEW "api"."claims" WITH (security_invoker=true) AS  SELECT id,
    campaign_id,
    user_id,
    status,
    expires_at,
    created_at
   FROM market.claims;

CREATE VIEW "api"."clip_earnings" WITH (security_invoker=true) AS  SELECT submission_id,
    rule_id,
    pool_id,
    amount,
    demand,
    released_at,
    updated_at
   FROM finance.clip_earnings;

CREATE VIEW "api"."fee_rules" WITH (security_invoker=true) AS  SELECT id,
    scope,
    mgmt_fee_pct,
    admin_fee_pct,
    clipper_fee_pct,
    instant_withdraw_fee
   FROM finance.fee_rules;

CREATE VIEW "api"."fraud_flags" WITH (security_invoker=true) AS  SELECT id,
    target_type,
    target_id,
    signal,
    score,
    status,
    details,
    resolved_by,
    resolved_at,
    created_at
   FROM trust.fraud_flags;

CREATE VIEW "api"."fulfillments" WITH (security_invoker=true) AS  SELECT id,
    user_id,
    reward_type_id,
    amount,
    recipient,
    status,
    delivered_ref,
    attempts,
    created_at,
    delivered_at
   FROM finance.fulfillments;

CREATE VIEW "api"."invoices" WITH (security_invoker=true) AS  SELECT id,
    number,
    org_id,
    campaign_id,
    kind,
    subtotal,
    mgmt_fee,
    admin_fee,
    service_fee,
    tax,
    total,
    status,
    payment_channel,
    paid_amount,
    paid_at,
    faktur_no,
    issued_at,
    due_at,
    pin_until,
    pool_topups
   FROM finance.invoices;

CREATE VIEW "api"."my_profile" WITH (security_invoker=true) AS  SELECT id,
    username,
    display_name,
    avatar_path,
    trust_score,
    status,
    suspended_until,
    created_at
   FROM market.profiles
  WHERE (id = ( SELECT auth.uid() AS uid));

CREATE VIEW "api"."notification_prefs" WITH (security_invoker=true) AS  SELECT user_id,
    email_promotions,
    updated_at
   FROM ops.notification_prefs;

CREATE VIEW "api"."notifications" WITH (security_invoker=true) AS  SELECT id,
    user_id,
    event,
    payload,
    read_at,
    created_at
   FROM ops.notifications;

CREATE VIEW "api"."org_invites" WITH (security_invoker=true) AS  SELECT id,
    org_id,
    role,
    expires_at,
    accepted_by,
    accepted_at,
    created_by,
    created_at
   FROM market.org_invites;

CREATE VIEW "api"."org_links" WITH (security_invoker=true) AS  SELECT agency_org_id,
    client_org_id,
    approved_by,
    approved_at,
    revoked_at,
    created_at
   FROM market.org_links;

CREATE VIEW "api"."org_members" WITH (security_invoker=true) AS  SELECT org_id,
    user_id,
    role,
    created_at
   FROM market.org_members;

CREATE VIEW "api"."org_refunds" WITH (security_invoker=true) AS  SELECT id,
    org_id,
    campaign_id,
    amount,
    transfer_fee,
    status,
    created_at,
    paid_at
   FROM finance.org_refunds;

CREATE VIEW "api"."organizations" WITH (security_invoker=true) AS  SELECT id,
    name,
    org_type,
    legal_name,
    npwp,
    address,
    is_agency,
    status,
    verified_at,
    created_at
   FROM market.organizations;

CREATE VIEW "api"."payout_batches" WITH (security_invoker=true) AS  SELECT id,
    created_by,
    approved_by,
    status,
    cutoff_at,
    total,
    count,
    executed_at,
    created_at
   FROM finance.payout_batches;

CREATE VIEW "api"."payouts" WITH (security_invoker=true) AS  SELECT id,
    user_id,
    method_id,
    batch_id,
    channel,
    amount,
    fee,
    status,
    hold_reason,
    created_at,
    paid_at
   FROM finance.payouts;

CREATE VIEW "api"."profiles" WITH (security_invoker=true) AS  SELECT id,
    username,
    display_name,
    avatar_path,
    created_at
   FROM market.profiles;

CREATE VIEW "api"."rate_rules" WITH (security_invoker=true) AS  SELECT id,
    campaign_id,
    kind,
    reward_type_id,
    pool_id,
    platform,
    params,
    effective_from,
    effective_to
   FROM market.rate_rules;

CREATE VIEW "api"."referrals" WITH (security_invoker=true) AS  SELECT r.referred_id,
    p.username AS referred_username,
    r.qualified_at,
    r.bonus_until,
    r.created_at
   FROM (market.referrals r
     JOIN market.profiles p ON ((p.id = r.referred_id)));

CREATE VIEW "api"."report_links" WITH (security_invoker=true) AS  SELECT id,
    campaign_id,
    created_by,
    expires_at,
    revoked_at,
    created_at
   FROM market.report_links;

CREATE VIEW "api"."review_decisions" WITH (security_invoker=true) AS  SELECT id,
    target_type,
    target_id,
    actor_id,
    decision,
    reason_code,
    message,
    created_at
   FROM trust.review_decisions;

CREATE VIEW "api"."reward_codes" WITH (security_invoker=true) AS  SELECT id,
    reward_type_id,
    code,
    fulfillment_id,
    created_at,
    assigned_at
   FROM finance.reward_codes;

CREATE VIEW "api"."reward_pools" WITH (security_invoker=true) AS  SELECT id,
    campaign_id,
    reward_type_id,
    total,
    allocated,
    (total - allocated) AS remaining,
    max_per_clip
   FROM finance.reward_pools;

CREATE VIEW "api"."reward_types" WITH (security_invoker=true) AS  SELECT id,
    owner_org_id,
    code,
    name,
    kind,
    unit_label,
    idr_value_per_unit,
    decimals,
    fulfillment,
    recipient_schema,
    stock
   FROM market.reward_types;

CREATE VIEW "api"."score_events" WITH (security_invoker=true) AS  SELECT id,
    user_id,
    delta,
    reason,
    created_at
   FROM trust.score_events;

CREATE VIEW "api"."settings" WITH (security_invoker=true) AS  SELECT key,
    value,
    updated_at
   FROM ops.settings;

CREATE VIEW "api"."social_accounts" WITH (security_invoker=true) AS  SELECT id,
    user_id,
    platform,
    external_id,
    handle,
    status,
    followers,
    platform_created_at,
    verified_at,
    created_at
   FROM tracking.social_accounts;

CREATE VIEW "api"."submissions" WITH (security_invoker=true) AS  SELECT id,
    claim_id,
    user_id,
    campaign_id,
    social_account_id,
    platform,
    post_id,
    url,
    posted_at,
    status,
    counted_views,
    last_snapshot_at,
    locked_at,
    created_at
   FROM tracking.submissions;

CREATE VIEW "api"."view_snapshots" WITH (security_invoker=true) AS  SELECT id,
    submission_id,
    taken_at,
    views,
    likes,
    comments,
    shares,
    is_final
   FROM tracking.view_snapshots;

CREATE VIEW "api"."wallet_balances" WITH (security_invoker=true) AS  SELECT a.owner_id AS user_id,
    e.reward_type_id,
    e.state,
    sum(e.amount) AS amount
   FROM (finance.ledger_entries e
     JOIN finance.ledger_accounts a ON ((a.id = e.account_id)))
  WHERE (a.owner_type = 'user_wallet'::text)
  GROUP BY a.owner_id, e.reward_type_id, e.state;

CREATE VIEW "api"."wallet_entries" WITH (security_invoker=true) AS  SELECT e.id,
    a.owner_id AS user_id,
    e.reward_type_id,
    e.amount,
    e.state,
    e.ref_type,
    e.ref_id,
    e.created_at
   FROM (finance.ledger_entries e
     JOIN finance.ledger_accounts a ON ((a.id = e.account_id)))
  WHERE (a.owner_type = 'user_wallet'::text);

CREATE MATERIALIZED VIEW "market"."leaderboard_campaign"
  AS  SELECT campaign_id,
    user_id,
    (sum(counted_views))::bigint AS views,
    (rank() OVER (PARTITION BY campaign_id ORDER BY (sum(counted_views)) DESC))::integer AS rank
   FROM tracking.submissions s
  WHERE (status = ANY (ARRAY['tracking'::tracking.submission_status, 'locked'::tracking.submission_status, 'settled'::tracking.submission_status]))
  GROUP BY campaign_id, user_id;

CREATE MATERIALIZED VIEW "market"."leaderboard_weekly"
  AS  SELECT date_trunc('week'::text, created_at) AS week_start,
    user_id,
    (sum(counted_views))::bigint AS views,
    (rank() OVER (PARTITION BY (date_trunc('week'::text, created_at)) ORDER BY (sum(counted_views)) DESC))::integer AS rank
   FROM tracking.submissions s
  WHERE (status = ANY (ARRAY['tracking'::tracking.submission_status, 'locked'::tracking.submission_status, 'settled'::tracking.submission_status]))
  GROUP BY (date_trunc('week'::text, created_at)), user_id;

CREATE VIEW "api"."leaderboard" WITH (security_invoker=true) AS  SELECT 'week'::text AS scope,
    w.week_start,
    NULL::uuid AS campaign_id,
    w.user_id,
    p.username,
    p.avatar_path,
    w.views,
    w.rank
   FROM (market.leaderboard_weekly w
     JOIN market.profiles p ON ((p.id = w.user_id)))
UNION ALL
 SELECT 'campaign'::text AS scope,
    NULL::timestamp with time zone AS week_start,
    c.campaign_id,
    c.user_id,
    p.username,
    p.avatar_path,
    c.views,
    c.rank
   FROM (market.leaderboard_campaign c
     JOIN market.profiles p ON ((p.id = c.user_id)))
  WHERE (EXISTS ( SELECT 1
           FROM market.campaigns k
          WHERE (k.id = c.campaign_id)));

CREATE INDEX clip_earnings_demand_snapshot_idx ON finance.clip_earnings USING btree (demand_snapshot);

CREATE INDEX clip_earnings_pool_idx ON finance.clip_earnings USING btree (pool_id);

CREATE INDEX clip_earnings_rule_idx ON finance.clip_earnings USING btree (rule_id);

CREATE UNIQUE INDEX fee_rules_one_global ON finance.fee_rules USING btree (scope)
  WHERE (scope = 'global'::text);

CREATE INDEX fulfillments_retry_idx ON finance.fulfillments USING btree (next_retry_at)
  WHERE (status = 'processing'::finance.fulfillment_status);

CREATE INDEX fulfillments_reward_type_idx ON finance.fulfillments USING btree (reward_type_id, status);

CREATE INDEX fulfillments_user_idx ON finance.fulfillments USING btree (user_id, created_at DESC);

CREATE INDEX invoices_campaign_idx ON finance.invoices USING btree (campaign_id);

CREATE INDEX invoices_org_idx ON finance.invoices USING btree (org_id, issued_at DESC);

CREATE INDEX ledger_accounts_owner_idx ON finance.ledger_accounts USING btree (owner_id, owner_type);

CREATE INDEX ledger_accounts_reward_type_idx ON finance.ledger_accounts USING btree (reward_type_id);

CREATE INDEX ledger_entries_account_idx ON finance.ledger_entries USING btree (account_id, state);

CREATE INDEX ledger_entries_txn_idx ON finance.ledger_entries USING btree (txn_id);

CREATE INDEX org_refunds_campaign_idx ON finance.org_refunds USING btree (campaign_id);

CREATE INDEX org_refunds_org_idx ON finance.org_refunds USING btree (org_id, created_at DESC);

CREATE INDEX payout_batches_status_idx ON finance.payout_batches USING btree (status, created_at DESC);

CREATE INDEX payouts_batch_idx ON finance.payouts USING btree (batch_id);

CREATE INDEX payouts_requested_idx ON finance.payouts USING btree (created_at)
  WHERE (status = 'requested'::finance.payout_status);

CREATE INDEX payouts_user_idx ON finance.payouts USING btree (user_id, created_at DESC);

CREATE INDEX reward_codes_available_idx ON finance.reward_codes USING btree (reward_type_id, created_at)
  WHERE (fulfillment_id IS NULL);

CREATE INDEX reward_pools_campaign_idx ON finance.reward_pools USING btree (campaign_id);

CREATE INDEX reward_pools_reward_type_idx ON finance.reward_pools USING btree (reward_type_id);

CREATE INDEX campaign_assets_campaign_idx ON market.campaign_assets USING btree (campaign_id);

CREATE INDEX campaign_invites_user_idx ON market.campaign_invites USING btree (user_id);

CREATE INDEX campaigns_category_idx ON market.campaigns USING btree (category_id);

CREATE INDEX campaigns_fee_rule_idx ON market.campaigns USING btree (fee_rule_id);

CREATE INDEX campaigns_managed_queue_idx ON market.campaigns USING btree (created_at)
  WHERE ((service_mode = 'managed'::text) AND (status = 'draft'::market.campaign_status));

CREATE INDEX campaigns_org_idx ON market.campaigns USING btree (org_id);

CREATE INDEX campaigns_pinned_idx ON market.campaigns USING btree (pinned_rank)
  WHERE (pinned_until IS NOT NULL);

CREATE INDEX campaigns_status_start_idx ON market.campaigns USING btree (status, start_at);

CREATE INDEX claims_campaign_idx ON market.claims USING btree (campaign_id, status);

CREATE INDEX claims_expiring_idx ON market.claims USING btree (expires_at)
  WHERE (status = 'open'::market.claim_status);

CREATE UNIQUE INDEX claims_one_open_per_campaign ON market.claims USING btree (campaign_id, user_id)
  WHERE (status = 'open'::market.claim_status);

CREATE INDEX claims_user_idx ON market.claims USING btree (user_id, created_at DESC);

CREATE UNIQUE INDEX leaderboard_campaign_key ON market.leaderboard_campaign USING btree (campaign_id, user_id);

CREATE UNIQUE INDEX leaderboard_weekly_key ON market.leaderboard_weekly USING btree (week_start, user_id);

CREATE INDEX org_invites_accepted_by_idx ON market.org_invites USING btree (accepted_by);

CREATE INDEX org_invites_created_by_idx ON market.org_invites USING btree (created_by);

CREATE INDEX org_invites_org_idx ON market.org_invites USING btree (org_id);

CREATE INDEX org_links_client_idx ON market.org_links USING btree (client_org_id);

CREATE INDEX org_members_user_idx ON market.org_members USING btree (user_id);

CREATE INDEX organizations_fee_rule_idx ON market.organizations USING btree (fee_rule_id);

CREATE INDEX rate_rules_campaign_idx ON market.rate_rules USING btree (campaign_id);

CREATE INDEX rate_rules_pool_idx ON market.rate_rules USING btree (pool_id, campaign_id, reward_type_id);

CREATE INDEX rate_rules_reward_type_idx ON market.rate_rules USING btree (reward_type_id);

CREATE INDEX referrals_referrer_idx ON market.referrals USING btree (referrer_id);

CREATE INDEX report_links_campaign_idx ON market.report_links USING btree (campaign_id);

CREATE INDEX report_links_created_by_idx ON market.report_links USING btree (created_by);

CREATE INDEX reward_types_owner_idx ON market.reward_types USING btree (owner_org_id);

CREATE INDEX alerts_open_idx ON ops.alerts USING btree (kind, created_at DESC)
  WHERE (resolved_at IS NULL);

CREATE INDEX audit_logs_actor_idx ON ops.audit_logs USING btree (actor_id, at DESC);

CREATE INDEX audit_logs_target_idx ON ops.audit_logs USING btree (target, at DESC);

CREATE INDEX broadcasts_pending_idx ON ops.broadcasts USING btree (scheduled_at)
  WHERE (sent_at IS NULL);

CREATE INDEX notifications_unread_idx ON ops.notifications USING btree (user_id)
  WHERE (read_at IS NULL);

CREATE INDEX notifications_user_idx ON ops.notifications USING btree (user_id, created_at DESC);

CREATE INDEX social_accounts_user_idx ON tracking.social_accounts USING btree (user_id, platform);

CREATE INDEX submissions_account_idx ON tracking.submissions USING btree (social_account_id, user_id, platform);

CREATE INDEX submissions_campaign_idx ON tracking.submissions USING btree (campaign_id, status);

CREATE INDEX submissions_due_idx ON tracking.submissions USING btree (next_poll_at)
  WHERE (status = ANY (ARRAY['tracking'::tracking.submission_status, 'flagged'::tracking.submission_status]));

CREATE INDEX submissions_post_idx ON tracking.submissions USING btree (platform, post_id);

CREATE INDEX submissions_user_idx ON tracking.submissions USING btree (user_id, created_at DESC);

CREATE UNIQUE INDEX view_snapshots_one_final ON tracking.view_snapshots USING btree (submission_id)
  WHERE is_final;

CREATE UNIQUE INDEX fraud_flags_one_open ON trust.fraud_flags USING btree (target_type, target_id, signal)
  WHERE (status = ANY (ARRAY['open'::text, 'held'::text]));

CREATE INDEX fraud_flags_queue_idx ON trust.fraud_flags USING btree (status, created_at);

CREATE UNIQUE INDEX review_one_appeal_per_submission ON trust.review_decisions USING btree (target_id)
  WHERE ((target_type = 'submission'::text) AND (decision = 'appeal'::text));

CREATE INDEX review_target_idx ON trust.review_decisions USING btree (target_type, target_id, created_at);

CREATE INDEX score_events_user_idx ON trust.score_events USING btree (user_id, created_at DESC);

CREATE TRIGGER fulfillments_state_machine
  BEFORE INSERT OR UPDATE OF status ON finance.fulfillments
  FOR EACH ROW
  EXECUTE FUNCTION
    ops.check_transition('S-06', 'requested',
    '{"requested":["on_hold","processing"],"on_hold":["processing","cancelled"],"processing":["delivered","failed"],"failed":["requested","returned"]}');

CREATE TRIGGER ledger_entries_append_only
  BEFORE DELETE OR UPDATE ON finance.ledger_entries
  FOR EACH ROW
  EXECUTE FUNCTION ops.reject_mutation();

CREATE CONSTRAINT TRIGGER ledger_entries_balanced
  AFTER INSERT ON finance.ledger_entries DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION finance.check_txn_balanced();

CREATE TRIGGER ledger_entries_bucket
  BEFORE INSERT ON finance.ledger_entries
  FOR EACH ROW
  EXECUTE FUNCTION finance.check_entry_bucket();

CREATE TRIGGER payouts_state_machine
  BEFORE INSERT OR UPDATE OF status ON finance.payouts
  FOR EACH ROW
  EXECUTE FUNCTION
    ops.check_transition('S-05', 'requested',
    '{"requested":["on_hold","processing"],"on_hold":["processing","cancelled"],"processing":["paid","failed"],"paid":["failed"],"failed":["requested","returned"]}');

CREATE TRIGGER campaigns_brief_frozen
  BEFORE UPDATE ON market.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION market.freeze_brief();

CREATE TRIGGER campaigns_cancel_refund
  AFTER UPDATE OF status ON market.campaigns
  FOR EACH ROW
  WHEN (((new.status = 'cancelled'::market.campaign_status) AND (old.status IS DISTINCT FROM new.status)))
  EXECUTE FUNCTION finance.on_campaign_cancelled();

CREATE TRIGGER campaigns_state_machine
  BEFORE INSERT OR UPDATE OF status ON market.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION
    ops.check_transition('S-01', 'draft',
    '{"draft":["in_review","cancelled"],"in_review":["scheduled","rejected","cancelled"],"rejected":["draft"],"scheduled":["live","cancelled"],"live":["paused","tracking","exhausted"],"paused":["live","tracking","exhausted"],"tracking":["settling","exhausted"],"exhausted":["settling"],"settling":["settled"]}');

CREATE TRIGGER claims_state_machine
  BEFORE INSERT OR UPDATE OF status ON market.claims
  FOR EACH ROW
  EXECUTE FUNCTION ops.check_transition('S-02', 'open', '{"open":["submitted","expired","released"]}');

CREATE TRIGGER org_members_keep_owner
  BEFORE DELETE OR UPDATE ON market.org_members
  FOR EACH ROW
  EXECUTE FUNCTION market.keep_one_owner();

CREATE TRIGGER audit_logs_append_only
  BEFORE DELETE OR UPDATE ON ops.audit_logs
  FOR EACH ROW
  EXECUTE FUNCTION ops.reject_mutation();

CREATE TRIGGER social_accounts_limit
  BEFORE INSERT OR UPDATE OF user_id, platform, status ON tracking.social_accounts
  FOR EACH ROW
  WHEN ((new.status <> 'disconnected'::text))
  EXECUTE FUNCTION tracking.check_account_limit();

CREATE TRIGGER submissions_state_machine
  BEFORE INSERT OR UPDATE OF status ON tracking.submissions
  FOR EACH ROW
  EXECUTE FUNCTION
    ops.check_transition('S-03', 'validating',
    '{"validating":["in_review","tracking","rejected"],"in_review":["tracking","rejected"],"rejected":["appealed"],"appealed":["tracking","rejected_final"],"tracking":["flagged","forfeited","locked"],"flagged":["tracking","forfeited"],"locked":["settled"]}');

CREATE TRIGGER view_snapshots_append_only
  BEFORE DELETE OR UPDATE ON tracking.view_snapshots
  FOR EACH ROW
  EXECUTE FUNCTION ops.reject_mutation();

CREATE TRIGGER review_decisions_append_only
  BEFORE DELETE OR UPDATE ON trust.review_decisions
  FOR EACH ROW
  EXECUTE FUNCTION ops.reject_mutation();

CREATE TRIGGER score_events_append_only
  BEFORE DELETE OR UPDATE ON trust.score_events
  FOR EACH ROW
  EXECUTE FUNCTION ops.reject_mutation();

CREATE POLICY "clip_earnings_iss" ON "finance"."clip_earnings"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "clip_earnings_visible" ON "finance"."clip_earnings"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM tracking.submissions s
  WHERE (s.id = clip_earnings.submission_id))));

CREATE POLICY "fee_rules_iss" ON "finance"."fee_rules"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "fee_rules_read" ON "finance"."fee_rules"
  FOR SELECT
  TO "authenticated"
  USING (((scope = 'global'::text) OR finance.fee_rule_visible(id) OR ( SELECT ops.has_admin() AS has_admin)));

CREATE POLICY "fulfillments_admin_read" ON "finance"."fulfillments"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_finance'::text, 'admin_ops'::text]) AS has_admin));

CREATE POLICY "fulfillments_iss" ON "finance"."fulfillments"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "fulfillments_own_read" ON "finance"."fulfillments"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "invoices_finance_read" ON "finance"."invoices"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_finance'::text]) AS has_admin));

CREATE POLICY "invoices_iss" ON "finance"."invoices"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "invoices_org_billing_read" ON "finance"."invoices"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.is_org_member(invoices.org_id, VARIADIC ARRAY['brand_owner'::market.org_role, 'brand_finance'::market.org_role]) AS is_org_member));

CREATE POLICY "ledger_accounts_admin_read" ON "finance"."ledger_accounts"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_finance'::text]) AS has_admin));

CREATE POLICY "ledger_accounts_iss" ON "finance"."ledger_accounts"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "ledger_accounts_org_credit" ON "finance"."ledger_accounts"
  FOR SELECT
  TO "authenticated"
  USING
    (((owner_type = 'org_credit'::text) AND ( SELECT ops.is_org_member(ledger_accounts.owner_id, VARIADIC ARRAY['brand_owner'::market.org_role, 'brand_finance'::market.org_role])
    AS is_org_member)));

CREATE POLICY "ledger_accounts_own_wallet" ON "finance"."ledger_accounts"
  FOR SELECT
  TO "authenticated"
  USING (((owner_type = 'user_wallet'::text) AND (owner_id = ( SELECT auth.uid() AS uid))));

CREATE POLICY "ledger_entries_iss" ON "finance"."ledger_entries"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "ledger_entries_visible" ON "finance"."ledger_entries"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM finance.ledger_accounts a
  WHERE (a.id = ledger_entries.account_id))));

CREATE POLICY "org_refunds_finance_read" ON "finance"."org_refunds"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_finance'::text]) AS has_admin));

CREATE POLICY "org_refunds_iss" ON "finance"."org_refunds"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "org_refunds_org_read" ON "finance"."org_refunds"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.is_org_member(org_refunds.org_id, VARIADIC ARRAY['brand_owner'::market.org_role, 'brand_finance'::market.org_role]) AS is_org_member));

CREATE POLICY "payout_batches_finance_read" ON "finance"."payout_batches"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_finance'::text]) AS has_admin));

CREATE POLICY "payout_batches_iss" ON "finance"."payout_batches"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "payouts_finance_read" ON "finance"."payouts"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_finance'::text]) AS has_admin));

CREATE POLICY "payouts_iss" ON "finance"."payouts"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "payouts_own_read" ON "finance"."payouts"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "pool_settlements_iss" ON "finance"."pool_settlements"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "pool_settlements_visible" ON "finance"."pool_settlements"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM finance.reward_pools p
  WHERE (p.id = pool_settlements.pool_id))));

CREATE POLICY "reward_codes_admin_read" ON "finance"."reward_codes"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_ops'::text, 'admin_finance'::text]) AS has_admin));

CREATE POLICY "reward_codes_iss" ON "finance"."reward_codes"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "reward_codes_own_read" ON "finance"."reward_codes"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM finance.fulfillments f
  WHERE (f.id = reward_codes.fulfillment_id))));

CREATE POLICY "reward_codes_owner_org_read" ON "finance"."reward_codes"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM market.reward_types rt
  WHERE ((rt.id = reward_codes.reward_type_id) AND (rt.owner_org_id IS
    NOT NULL) AND ( SELECT ops.is_org_member(rt.owner_org_id, VARIADIC ARRAY['brand_owner'::market.org_role, 'brand_manager'::market.org_role]) AS is_org_member)))));

CREATE POLICY "reward_pools_iss" ON "finance"."reward_pools"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "reward_pools_visible" ON "finance"."reward_pools"
  FOR SELECT
  TO "anon", "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE (c.id = reward_pools.campaign_id))));

CREATE POLICY "budget_alerts_admin_read" ON "market"."budget_alerts"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "budget_alerts_iss" ON "market"."budget_alerts"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "budget_alerts_org_read" ON "market"."budget_alerts"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE ((c.id = budget_alerts.campaign_id) AND ( SELECT ops.is_org_member(c.org_id) AS is_org_member)))));

CREATE POLICY "campaign_assets_cover_public" ON "market"."campaign_assets"
  FOR SELECT
  TO "anon"
  USING (((kind = 'cover'::text) AND (audience = 'clipper'::text) AND (EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE (c.id = campaign_assets.campaign_id)))));

CREATE POLICY "campaign_assets_iss" ON "market"."campaign_assets"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "campaign_assets_visible" ON "market"."campaign_assets"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE
    ((c.id = campaign_assets.campaign_id) AND ((campaign_assets.audience = 'clipper'::text) OR ( SELECT ops.is_org_member(c.org_id) AS is_org_member) OR ( SELECT ops.has_admin() AS
    has_admin))))));

CREATE POLICY "campaign_invites_admin_read" ON "market"."campaign_invites"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "campaign_invites_iss" ON "market"."campaign_invites"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "campaign_invites_org_read" ON "market"."campaign_invites"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE ((c.id = campaign_invites.campaign_id) AND ( SELECT ops.is_org_member(c.org_id) AS is_org_member)))));

CREATE POLICY "campaign_invites_own_read" ON "market"."campaign_invites"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "campaigns_admin_read" ON "market"."campaigns"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "campaigns_iss" ON "market"."campaigns"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "campaigns_org_read" ON "market"."campaigns"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.is_org_member(campaigns.org_id) AS is_org_member));

CREATE POLICY "campaigns_public_anon" ON "market"."campaigns"
  FOR SELECT
  TO "anon"
  USING
    (((status = ANY (ARRAY['live'::market.campaign_status, 'paused'::market.campaign_status, 'tracking'::market.campaign_status, 'exhausted'::market.campaign_status,
    'settling'::market.campaign_status, 'settled'::market.campaign_status])) AND (NOT is_template) AND (visibility = 'public'::text)));

CREATE POLICY "campaigns_public_auth" ON "market"."campaigns"
  FOR SELECT
  TO "authenticated"
  USING
    (((status = ANY (ARRAY['live'::market.campaign_status, 'paused'::market.campaign_status, 'tracking'::market.campaign_status, 'exhausted'::market.campaign_status,
    'settling'::market.campaign_status,
    'settled'::market.campaign_status])) AND (NOT is_template) AND
    ((visibility = 'public'::text) OR ((visibility = 'invite'::text) AND market.is_invited(id)) OR ((visibility = 'level'::text) AND (EXISTS ( SELECT 1
   FROM market.profiles p
  WHERE ((p.id = ( SELECT auth.uid() AS uid)) AND (p.trust_score >= campaigns.min_trust_score))))))));

CREATE POLICY "categories_admin_read" ON "market"."categories"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "categories_iss" ON "market"."categories"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "categories_public_read" ON "market"."categories"
  FOR SELECT
  TO "anon", "authenticated"
  USING (active);

CREATE POLICY "claims_admin_read" ON "market"."claims"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "claims_iss" ON "market"."claims"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "claims_org_read" ON "market"."claims"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE ((c.id = claims.campaign_id) AND ( SELECT ops.is_org_member(c.org_id) AS is_org_member)))));

CREATE POLICY "claims_own_read" ON "market"."claims"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "org_invites_iss" ON "market"."org_invites"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "org_invites_owner_read" ON "market"."org_invites"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.is_org_member(org_invites.org_id, VARIADIC ARRAY['brand_owner'::market.org_role]) AS is_org_member));

CREATE POLICY "org_links_admin_read" ON "market"."org_links"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "org_links_iss" ON "market"."org_links"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "org_links_party_read" ON "market"."org_links"
  FOR SELECT
  TO "authenticated"
  USING
    ((( SELECT ops.is_org_member(org_links.agency_org_id) AS is_org_member) OR ( SELECT ops.is_org_member(org_links.client_org_id, VARIADIC ARRAY['brand_owner'::market.org_role])
    AS is_org_member)));

CREATE POLICY "org_members_admin_read" ON "market"."org_members"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "org_members_iss" ON "market"."org_members"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "org_members_same_org_read" ON "market"."org_members"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.is_org_member(org_members.org_id) AS is_org_member));

CREATE POLICY "organizations_admin_read" ON "market"."organizations"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "organizations_iss" ON "market"."organizations"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "organizations_member_read" ON "market"."organizations"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.is_org_member(organizations.id) AS is_org_member));

CREATE POLICY "profiles_iss" ON "market"."profiles"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "profiles_public_read" ON "market"."profiles"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

CREATE POLICY "rate_rules_iss" ON "market"."rate_rules"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "rate_rules_visible" ON "market"."rate_rules"
  FOR SELECT
  TO "anon", "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE (c.id = rate_rules.campaign_id))));

CREATE POLICY "referrals_admin_read" ON "market"."referrals"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "referrals_iss" ON "market"."referrals"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "referrals_referrer_read" ON "market"."referrals"
  FOR SELECT
  TO "authenticated"
  USING ((referrer_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "report_links_iss" ON "market"."report_links"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "report_links_org_read" ON "market"."report_links"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE ((c.id = report_links.campaign_id) AND ( SELECT ops.is_org_member(c.org_id) AS is_org_member)))));

CREATE POLICY "reward_types_iss" ON "market"."reward_types"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "reward_types_public_read" ON "market"."reward_types"
  FOR SELECT
  TO "anon", "authenticated"
  USING (true);

CREATE POLICY "alerts_admin_read" ON "ops"."alerts"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "alerts_iss" ON "ops"."alerts"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "audit_logs_iss" ON "ops"."audit_logs"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "audit_logs_super_read" ON "ops"."audit_logs"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_super'::text]) AS has_admin));

CREATE POLICY "broadcasts_admin_read" ON "ops"."broadcasts"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_ops'::text]) AS has_admin));

CREATE POLICY "broadcasts_iss" ON "ops"."broadcasts"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "notification_prefs_iss" ON "ops"."notification_prefs"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "notification_prefs_own" ON "ops"."notification_prefs"
  FOR ALL
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)))
  WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "notifications_iss" ON "ops"."notifications"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "notifications_own_mark_read" ON "ops"."notifications"
  FOR UPDATE
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)))
  WITH CHECK ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "notifications_own_read" ON "ops"."notifications"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "settings_admin_read" ON "ops"."settings"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "settings_iss" ON "ops"."settings"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "settings_public_read" ON "ops"."settings"
  FOR SELECT
  TO "anon", "authenticated"
  USING ((key ~~ 'public.%'::text));

CREATE POLICY "avatars_own_update" ON "storage"."objects"
  FOR UPDATE
  TO "authenticated"
  USING (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = ( SELECT (auth.jwt() ->> 'sub'::text)))));

CREATE POLICY "avatars_own_write" ON "storage"."objects"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (((bucket_id = 'avatars'::text) AND ((storage.foldername(name))[1] = ( SELECT (auth.jwt() ->> 'sub'::text)))));

CREATE POLICY "campaign_assets_read" ON "storage"."objects"
  FOR SELECT
  TO "authenticated"
  USING (((bucket_id = 'campaign-assets'::text) AND (EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE
    ((c.id = ((storage.foldername(objects.name))[2])::uuid) AND (((storage.foldername(objects.name))[3] IS DISTINCT FROM 'internal'::text) OR ( SELECT ops.is_org_member(c.org_id)
    AS is_org_member) OR ( SELECT ops.has_admin() AS has_admin)))))));

CREATE POLICY "campaign_files_write" ON "storage"."objects"
  FOR INSERT
  TO "authenticated"
  WITH
    CHECK
    (((bucket_id = ANY (ARRAY['campaign-covers'::text, 'campaign-assets'::text])) AND (( SELECT ops.is_org_member(((storage.foldername(objects.name))[1])::uuid, VARIADIC
    ARRAY['brand_owner'::market.org_role, 'brand_manager'::market.org_role]) AS is_org_member) OR ( SELECT ops.has_admin(VARIADIC ARRAY['admin_ops'::text]) AS has_admin))));

CREATE POLICY "social_accounts_admin_read" ON "tracking"."social_accounts"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_moderator'::text, 'admin_support'::text]) AS has_admin));

CREATE POLICY "social_accounts_iss" ON "tracking"."social_accounts"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "social_accounts_own_read" ON "tracking"."social_accounts"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "submissions_admin_read" ON "tracking"."submissions"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "submissions_iss" ON "tracking"."submissions"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "submissions_org_read" ON "tracking"."submissions"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE ((c.id = submissions.campaign_id) AND ( SELECT ops.is_org_member(c.org_id) AS is_org_member)))));

CREATE POLICY "submissions_own_read" ON "tracking"."submissions"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

CREATE POLICY "view_snapshots_iss" ON "tracking"."view_snapshots"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "view_snapshots_visible" ON "tracking"."view_snapshots"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM tracking.submissions s
  WHERE (s.id = view_snapshots.submission_id))));

CREATE POLICY "fraud_flags_admin_read" ON "trust"."fraud_flags"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_moderator'::text, 'admin_finance'::text]) AS has_admin));

CREATE POLICY "fraud_flags_iss" ON "trust"."fraud_flags"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "review_decisions_admin_read" ON "trust"."review_decisions"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin() AS has_admin));

CREATE POLICY "review_decisions_iss" ON "trust"."review_decisions"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "review_decisions_subject_read" ON "trust"."review_decisions"
  FOR SELECT
  TO "authenticated"
  USING ((((target_type = 'submission'::text) AND (EXISTS ( SELECT 1
   FROM tracking.submissions s
  WHERE (s.id = review_decisions.target_id)))) OR ((target_type = 'campaign'::text) AND (EXISTS ( SELECT 1
   FROM market.campaigns c
  WHERE ((c.id = review_decisions.target_id) AND ( SELECT ops.is_org_member(c.org_id) AS is_org_member))))) OR
    ((target_type = 'kyc'::text) AND (target_id = ( SELECT auth.uid() AS uid))) OR
    ((target_type = 'org'::text) AND ( SELECT ops.is_org_member(review_decisions.target_id) AS is_org_member))));

CREATE POLICY "score_events_admin_read" ON "trust"."score_events"
  FOR SELECT
  TO "authenticated"
  USING (( SELECT ops.has_admin(VARIADIC ARRAY['admin_moderator'::text, 'admin_support'::text]) AS has_admin));

CREATE POLICY "score_events_iss" ON "trust"."score_events"
  AS RESTRICTIVE
  FOR ALL
  TO "authenticated"
  USING (( SELECT ops.iss_ok() AS iss_ok))
  WITH CHECK (( SELECT ops.iss_ok() AS iss_ok));

CREATE POLICY "score_events_own_read" ON "trust"."score_events"
  FOR SELECT
  TO "authenticated"
  USING ((user_id = ( SELECT auth.uid() AS uid)));

COMMENT ON EXTENSION "pg_cron" IS 'Job scheduler for PostgreSQL';

COMMENT ON EXTENSION "pg_net" IS 'Async HTTP';

COMMENT ON EXTENSION "pgmq" IS 'A lightweight message queue. Like AWS SQS and RSMQ but on Postgres.';

REVOKE ALL ON FUNCTION "api"."accept_org_invite"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."accept_org_invite"(text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."accept_org_invite"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."accept_org_invite"(text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."admin_overview"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."admin_overview"() TO "authenticated";

REVOKE ALL ON FUNCTION "api"."admin_overview"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."admin_overview"() TO "postgres";

REVOKE ALL ON FUNCTION "api"."appeal_submission"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."appeal_submission"(uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."appeal_submission"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."appeal_submission"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."approve_payout_batch"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."approve_payout_batch"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."approve_payout_batch"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."approve_payout_batch"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "api"."approve_refund"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."approve_refund"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."approve_refund"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."approve_refund"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "api"."bridge_attach_export"(uuid, text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_attach_export"(uuid, text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_attach_export"(uuid, text, jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_attach_export"(uuid, text, jsonb) TO "service_role";

REVOKE ALL ON FUNCTION "api"."bridge_attach_proof"(text, uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_attach_proof"(text, uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_attach_proof"(text, uuid, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_attach_proof"(text, uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."bridge_close_account"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_close_account"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_close_account"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_close_account"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."bridge_collect_ids"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_collect_ids"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_collect_ids"() TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_collect_ids"() TO "service_role";

REVOKE ALL ON FUNCTION "api"."bridge_fulfillment_export"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_fulfillment_export"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_fulfillment_export"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_fulfillment_export"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."bridge_get_batch"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_get_batch"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_get_batch"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_get_batch"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."bridge_get_payout"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_get_payout"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_get_payout"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_get_payout"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."bridge_mark_instant"(uuid, text, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_mark_instant"(uuid, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_mark_instant"(uuid, text, text, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_mark_instant"(uuid, text, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."bridge_pph21"(date, date) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_pph21"(date, date) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_pph21"(date, date) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_pph21"(date, date) TO "service_role";

REVOKE ALL ON FUNCTION "api"."bridge_raise_fraud_flag"(text, uuid, text, numeric, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_raise_fraud_flag"(text, uuid, text, numeric, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_raise_fraud_flag"(text, uuid, text, numeric, jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_raise_fraud_flag"(text, uuid, text, numeric, jsonb) TO "service_role";

REVOKE ALL ON FUNCTION "api"."bridge_report_orphans"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_report_orphans"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_report_orphans"(jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_report_orphans"(jsonb) TO "service_role";

REVOKE ALL ON FUNCTION "api"."buy_pin"(uuid, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."buy_pin"(uuid, integer) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."buy_pin"(uuid, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."buy_pin"(uuid, integer) TO "postgres";

REVOKE ALL ON FUNCTION "api"."campaign_detail"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."campaign_detail"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."campaign_detail"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."campaign_detail"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "api"."campaign_stats"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."campaign_stats"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."campaign_stats"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."campaign_stats"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "api"."cancel_fulfillment"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."cancel_fulfillment"(uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."cancel_fulfillment"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."cancel_fulfillment"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."cancel_payout"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."cancel_payout"(uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."cancel_payout"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."cancel_payout"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."claim_campaign"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."claim_campaign"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."claim_campaign"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."claim_campaign"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "api"."confirm_invoice_payment"(uuid, numeric, timestamp WITH time zone, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."confirm_invoice_payment"(uuid, numeric, timestamp WITH time zone, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."confirm_invoice_payment"(uuid, numeric, timestamp WITH time zone, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."confirm_invoice_payment"(uuid, numeric, timestamp WITH time zone, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."control_campaign"(uuid, text, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."control_campaign"(uuid, text, jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."control_campaign"(uuid, text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."control_campaign"(uuid, text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "api"."create_org"(text, text, text, text, text, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."create_org"(text, text, text, text, text, boolean) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."create_org"(text, text, text, text, text, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."create_org"(text, text, text, text, text, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "api"."create_org_invite"(uuid, market.org_role) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."create_org_invite"(uuid, market.org_role) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."create_org_invite"(uuid, market.org_role) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."create_org_invite"(uuid, market.org_role) TO "postgres";

REVOKE ALL ON FUNCTION "api"."create_payout_batch"(timestamp WITH time zone) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."create_payout_batch"(timestamp WITH time zone) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."create_payout_batch"(timestamp WITH time zone) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."create_payout_batch"(timestamp WITH time zone) TO "postgres";

REVOKE ALL ON FUNCTION "api"."create_report_link"(uuid, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."create_report_link"(uuid, integer) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."create_report_link"(uuid, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."create_report_link"(uuid, integer) TO "postgres";

REVOKE ALL ON FUNCTION "api"."duplicate_campaign"(uuid, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."duplicate_campaign"(uuid, boolean) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."duplicate_campaign"(uuid, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."duplicate_campaign"(uuid, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "api"."ensure_profile"(text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."ensure_profile"(text, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."ensure_profile"(text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."ensure_profile"(text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."invite_to_campaign"(uuid, text[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."invite_to_campaign"(uuid, text[]) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."invite_to_campaign"(uuid, text[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."invite_to_campaign"(uuid, text[]) TO "postgres";

REVOKE ALL ON FUNCTION "api"."link_agency"(uuid, uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."link_agency"(uuid, uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."link_agency"(uuid, uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."link_agency"(uuid, uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."list_campaigns"(jsonb, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."list_campaigns"(jsonb, text) TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "api"."list_campaigns"(jsonb, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."list_campaigns"(jsonb, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."manage_org"(uuid, text, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."manage_org"(uuid, text, jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."manage_org"(uuid, text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."manage_org"(uuid, text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "api"."mark_batch_paid"(uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."mark_batch_paid"(uuid, jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."mark_batch_paid"(uuid, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."mark_batch_paid"(uuid, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "api"."missing_brief_tags"(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."missing_brief_tags"(uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."missing_brief_tags"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."missing_brief_tags"(uuid, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."missing_brief_tags"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."my_referral_code"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."my_referral_code"() TO "authenticated";

REVOKE ALL ON FUNCTION "api"."my_referral_code"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."my_referral_code"() TO "postgres";

REVOKE ALL ON FUNCTION "api"."my_stats"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."my_stats"() TO "authenticated";

REVOKE ALL ON FUNCTION "api"."my_stats"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."my_stats"() TO "postgres";

REVOKE ALL ON FUNCTION "api"."record_review"(text, uuid, text, text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."record_review"(text, uuid, text, text, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."record_review"(text, uuid, text, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."record_review"(text, uuid, text, text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."report_by_token"(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."report_by_token"(text) TO "anon", "authenticated";

REVOKE ALL ON FUNCTION "api"."report_by_token"(text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."report_by_token"(text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."request_fulfillment"(uuid, numeric, jsonb, uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."request_fulfillment"(uuid, numeric, jsonb, uuid, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."request_fulfillment"(uuid, numeric, jsonb, uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."request_fulfillment"(uuid, numeric, jsonb, uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."request_payout"(uuid, numeric, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."request_payout"(uuid, numeric, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."request_payout"(uuid, numeric, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."request_payout"(uuid, numeric, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."request_refund"(uuid, uuid, text, numeric, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."request_refund"(uuid, uuid, text, numeric, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."request_refund"(uuid, uuid, text, numeric, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."request_refund"(uuid, uuid, text, numeric, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."resolve_alert"(bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."resolve_alert"(bigint) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."resolve_alert"(bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."resolve_alert"(bigint) TO "postgres";

REVOKE ALL ON FUNCTION "api"."resolve_fraud_flag"(uuid, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."resolve_fraud_flag"(uuid, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."resolve_fraud_flag"(uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."resolve_fraud_flag"(uuid, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "api"."revoke_report_link"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."revoke_report_link"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."revoke_report_link"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."revoke_report_link"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "api"."save_campaign"(jsonb, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."save_campaign"(jsonb, boolean) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."save_campaign"(jsonb, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."save_campaign"(jsonb, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "api"."save_reward_type"(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."save_reward_type"(jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."save_reward_type"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."save_reward_type"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "api"."send_broadcast"(text, text, jsonb, text[], timestamp WITH time zone) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."send_broadcast"(text, text, jsonb, text[], timestamp WITH time zone) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."send_broadcast"(text, text, jsonb, text[], timestamp WITH time zone) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."send_broadcast"(text, text, jsonb, text[], timestamp WITH time zone) TO "postgres";

REVOKE ALL ON FUNCTION "api"."store_social_token"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."store_social_token"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."store_social_token"(uuid, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."store_social_token"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."update_config"(text, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."update_config"(text, jsonb) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."update_config"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."update_config"(text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "api"."upload_reward_codes"(uuid, text[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."upload_reward_codes"(uuid, text[]) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."upload_reward_codes"(uuid, text[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."upload_reward_codes"(uuid, text[]) TO "postgres";

REVOKE ALL ON FUNCTION "api"."worker_account_status"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_account_status"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_account_status"(uuid, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_account_status"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_account_token"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_account_token"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_account_token"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_account_token"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_accounts_to_refresh"(interval) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_accounts_to_refresh"(interval) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_accounts_to_refresh"(interval) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_accounts_to_refresh"(interval) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_ack"(text, bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_ack"(text, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_ack"(text, bigint) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_ack"(text, bigint) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_assign_code"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_assign_code"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_assign_code"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_assign_code"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_create_submission"(uuid, uuid, uuid, text, text, timestamp WITH time zone, text, integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_create_submission"(uuid, uuid, uuid, text, text, timestamp WITH time zone, text, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_create_submission"(uuid, uuid, uuid, text, text, timestamp WITH time zone, text, integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_create_submission"(uuid, uuid, uuid, text, text, timestamp WITH time zone, text, integer) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_defer"(uuid, timestamp WITH time zone) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_defer"(uuid, timestamp WITH time zone) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_defer"(uuid, timestamp WITH time zone) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_defer"(uuid, timestamp WITH time zone) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_dequeue"(text, integer, integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_dequeue"(text, integer, integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_dequeue"(text, integer, integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_dequeue"(text, integer, integer) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_fulfillment_result"(uuid, boolean, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_fulfillment_result"(uuid, boolean, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_fulfillment_result"(uuid, boolean, text, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_fulfillment_result"(uuid, boolean, text, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_fulfillments_due"(integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_fulfillments_due"(integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_fulfillments_due"(integer) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_fulfillments_due"(integer) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_notification"(bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_notification"(bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_notification"(bigint) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_notification"(bigint) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_post_gone"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_post_gone"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_post_gone"(uuid, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_post_gone"(uuid, text) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_record_snapshot"(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_record_snapshot"(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_record_snapshot"(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_record_snapshot"(uuid, bigint, bigint, bigint, bigint, text, jsonb, jsonb) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_submission_context"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_submission_context"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_submission_context"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_submission_context"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_unsubscribe"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_unsubscribe"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_unsubscribe"(uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_unsubscribe"(uuid) TO "service_role";

REVOKE ALL ON FUNCTION "api"."worker_upsert_social_account"(uuid, market.platform, text, text, integer, timestamp WITH time zone, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_upsert_social_account"(uuid, market.platform, text, text, integer, timestamp WITH time zone, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_upsert_social_account"(uuid, market.platform, text, text, integer, timestamp WITH time zone, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_upsert_social_account"(uuid, market.platform, text, text, integer, timestamp WITH time zone, text) TO "service_role";

REVOKE ALL ON FUNCTION "finance"."account"(text, uuid, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."account"(text, uuid, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."account"(text, uuid, uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."accrue_earnings"(uuid, bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."accrue_earnings"(uuid, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."accrue_earnings"(uuid, bigint) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."accrue_referral_bonus"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."accrue_referral_bonus"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."accrue_referral_bonus"() TO "postgres";

REVOKE ALL ON FUNCTION "finance"."amount_ref"(uuid, numeric) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."amount_ref"(uuid, numeric) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."amount_ref"(uuid, numeric) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."balance"(uuid, finance.earning_state) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."balance"(uuid, finance.earning_state) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."balance"(uuid, finance.earning_state) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."campaign_budget_idr"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."campaign_budget_idr"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."campaign_budget_idr"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."check_entry_bucket"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."check_entry_bucket"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."check_entry_bucket"() TO "postgres";

REVOKE ALL ON FUNCTION "finance"."check_exhausted"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."check_exhausted"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."check_exhausted"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."check_txn_balanced"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."check_txn_balanced"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."check_txn_balanced"() TO "postgres";

REVOKE ALL ON FUNCTION "finance"."correct_down"(uuid, bigint, bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."correct_down"(uuid, bigint, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."correct_down"(uuid, bigint, bigint) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."create_fee_rule"(text, jsonb, finance.fee_rules, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."create_fee_rule"(text, jsonb, finance.fee_rules, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."create_fee_rule"(text, jsonb, finance.fee_rules, uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."e"(uuid, numeric, text, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."e"(uuid, numeric, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."e"(uuid, numeric, text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."effective_fee_rule"(uuid, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."effective_fee_rule"(uuid, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."effective_fee_rule"(uuid, uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."fee_rule_visible"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "finance"."fee_rule_visible"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "finance"."fee_rule_visible"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."fee_rule_visible"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."finalize_settlements"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."finalize_settlements"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."finalize_settlements"() TO "postgres";

REVOKE ALL ON FUNCTION "finance"."idr"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."idr"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."idr"() TO "postgres";

REVOKE ALL ON FUNCTION "finance"."issue_invoice"(uuid, uuid, text, numeric, numeric, timestamp WITH time zone, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."issue_invoice"(uuid, uuid, text, numeric, numeric, timestamp WITH time zone, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."issue_invoice"(uuid, uuid, text, numeric, numeric, timestamp WITH time zone, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."next_invoice_number"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."next_invoice_number"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."next_invoice_number"() TO "postgres";

REVOKE ALL ON FUNCTION "finance"."noncash_value_idr"(uuid, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."noncash_value_idr"(uuid, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."noncash_value_idr"(uuid, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."on_campaign_cancelled"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."on_campaign_cancelled"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."on_campaign_cancelled"() TO "postgres";

REVOKE ALL ON FUNCTION "finance"."pay_refund"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."pay_refund"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."pay_refund"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."post"(uuid, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."post"(uuid, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."post"(uuid, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."refund_cancelled_campaign"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."refund_cancelled_campaign"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."refund_cancelled_campaign"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."release_earnings"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."release_earnings"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."release_earnings"() TO "postgres";

REVOKE ALL ON FUNCTION "finance"."require_active_clipper"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."require_active_clipper"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."require_active_clipper"() TO "postgres";

REVOKE ALL ON FUNCTION "finance"."retry_instant_payouts"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."retry_instant_payouts"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."retry_instant_payouts"() TO "postgres";

REVOKE ALL ON FUNCTION "finance"."return_payout"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."return_payout"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."return_payout"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."reverse_earning"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."reverse_earning"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."reverse_earning"(uuid, text) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."rule_amount"(text, jsonb, bigint, bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."rule_amount"(text, jsonb, bigint, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."rule_amount"(text, jsonb, bigint, bigint) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."settle_pool"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."settle_pool"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."settle_pool"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."start_settlement"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."start_settlement"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."start_settlement"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."topup_cash_idr"(uuid, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."topup_cash_idr"(uuid, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."topup_cash_idr"(uuid, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "finance"."unwind_payout_journal"(finance.payouts) FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."unwind_payout_journal"(finance.payouts) FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."unwind_payout_journal"(finance.payouts) TO "postgres";

REVOKE ALL ON FUNCTION "market"."announce_campaign"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."announce_campaign"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."announce_campaign"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "market"."campaign_budget"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."campaign_budget"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."campaign_budget"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "market"."campaign_projection"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."campaign_projection"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."campaign_projection"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "market"."campaign_ref"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."campaign_ref"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."campaign_ref"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "market"."campaign_report"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."campaign_report"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."campaign_report"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "market"."campaign_visible"(market.campaigns) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."campaign_visible"(market.campaigns) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."campaign_visible"(market.campaigns) TO "postgres";

REVOKE ALL ON FUNCTION "market"."check_rule_params"(text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."check_rule_params"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."check_rule_params"(text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "market"."claim_check"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."claim_check"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."claim_check"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "market"."decide_org"(uuid, text, uuid, text, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."decide_org"(uuid, text, uuid, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."decide_org"(uuid, text, uuid, text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "market"."ensure_member_profile"(uuid, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."ensure_member_profile"(uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."ensure_member_profile"(uuid, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "market"."fail"(text, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."fail"(text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."fail"(text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "market"."freeze_brief"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."freeze_brief"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."freeze_brief"() TO "postgres";

REVOKE ALL ON FUNCTION "market"."is_direct_member"(uuid, uuid, market.org_role[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."is_direct_member"(uuid, uuid, market.org_role[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."is_direct_member"(uuid, uuid, market.org_role[]) TO "postgres";

REVOKE ALL ON FUNCTION "market"."is_invited"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "market"."is_invited"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "market"."is_invited"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."is_invited"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "market"."jnum"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."jnum"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."jnum"(jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "market"."keep_one_owner"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."keep_one_owner"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."keep_one_owner"() TO "postgres";

REVOKE ALL ON FUNCTION "market"."norm_list"(jsonb, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."norm_list"(jsonb, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."norm_list"(jsonb, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "market"."notify_org"(uuid, market.org_role[], text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."notify_org"(uuid, market.org_role[], text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."notify_org"(uuid, market.org_role[], text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "market"."refresh_leaderboard"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."refresh_leaderboard"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."refresh_leaderboard"() TO "postgres";

REVOKE ALL ON FUNCTION "market"."rule_rate"(text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."rule_rate"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."rule_rate"(text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "market"."run_budget_alerts"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."run_budget_alerts"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."run_budget_alerts"() TO "postgres";

REVOKE ALL ON FUNCTION "market"."run_claim_expiry"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."run_claim_expiry"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."run_claim_expiry"() TO "postgres";

REVOKE ALL ON FUNCTION "market"."run_lifecycle"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."run_lifecycle"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."run_lifecycle"() TO "postgres";

REVOKE ALL ON FUNCTION "market"."session_uid"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "market"."session_uid"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "market"."session_uid"() TO "postgres";

REVOKE ALL ON FUNCTION "ops"."cfg"(text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."cfg"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."cfg"(text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."check_transition"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."check_transition"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."check_transition"() TO "postgres";

REVOKE ALL ON FUNCTION "ops"."dispatch_broadcasts"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."dispatch_broadcasts"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."dispatch_broadcasts"() TO "postgres";

REVOKE ALL ON FUNCTION "ops"."enqueue_notification"(uuid, text, jsonb, boolean) FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."enqueue_notification"(uuid, text, jsonb, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."enqueue_notification"(uuid, text, jsonb, boolean) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."has_admin"(text[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "ops"."has_admin"(text[]) TO "authenticated";

REVOKE ALL ON FUNCTION "ops"."has_admin"(text[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."has_admin"(text[]) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."invoke_function"(text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."invoke_function"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."invoke_function"(text, jsonb) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."is_org_member"(uuid, market.org_role[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "ops"."is_org_member"(uuid, market.org_role[]) TO "authenticated";

REVOKE ALL ON FUNCTION "ops"."is_org_member"(uuid, market.org_role[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."is_org_member"(uuid, market.org_role[]) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."iss_ok"() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "ops"."iss_ok"() TO "authenticated";

REVOKE ALL ON FUNCTION "ops"."iss_ok"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."iss_ok"() TO "postgres";

REVOKE ALL ON FUNCTION "ops"."org_role"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "ops"."org_role"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "ops"."org_role"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."org_role"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."raise_alert"(text, text, jsonb, interval) FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."raise_alert"(text, text, jsonb, interval) FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."raise_alert"(text, text, jsonb, interval) TO "postgres";

REVOKE ALL ON FUNCTION "ops"."reject_mutation"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "ops"."reject_mutation"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "ops"."reject_mutation"() TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."check_account_limit"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."check_account_limit"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."check_account_limit"() TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."enqueue_due_submissions"(integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."enqueue_due_submissions"(integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."enqueue_due_submissions"(integer) TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."final_due"(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."final_due"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."final_due"(uuid) TO "postgres";

REVOKE ALL ON FUNCTION "trust"."apply_submission_decision"(uuid, text, uuid, text, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "trust"."apply_submission_decision"(uuid, text, uuid, text, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "trust"."apply_submission_decision"(uuid, text, uuid, text, text, text) TO "postgres";

REVOKE ALL ON FUNCTION "trust"."auto_approve_overdue"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "trust"."auto_approve_overdue"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "trust"."auto_approve_overdue"() TO "postgres";

REVOKE ALL ON FUNCTION "trust"."raise_flag"(text, uuid, text, numeric, jsonb, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "trust"."raise_flag"(text, uuid, text, numeric, jsonb, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "trust"."raise_flag"(text, uuid, text, numeric, jsonb, text) TO "postgres";

REVOKE ALL ON FUNCTION "trust"."recalc_scores"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "trust"."recalc_scores"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "trust"."recalc_scores"() TO "postgres";

GRANT SELECT ON TABLE "market"."leaderboard_campaign" TO "authenticated";

GRANT SELECT ON TABLE "market"."leaderboard_weekly" TO "authenticated";

GRANT USAGE ON SCHEMA "api" TO "anon", "authenticated", "service_role";

GRANT SELECT ON TABLE "finance"."clip_earnings" TO "authenticated";

GRANT SELECT ON TABLE "finance"."fee_rules" TO "authenticated";

GRANT SELECT ON TABLE "finance"."fulfillments" TO "authenticated";

GRANT SELECT ON TABLE "finance"."invoices" TO "authenticated";

GRANT SELECT ON TABLE "finance"."ledger_accounts" TO "authenticated";

GRANT SELECT ON TABLE "finance"."ledger_entries" TO "authenticated";

GRANT SELECT ON TABLE "finance"."org_refunds" TO "authenticated";

GRANT SELECT ON TABLE "finance"."payout_batches" TO "authenticated";

GRANT SELECT ON TABLE "finance"."payouts" TO "authenticated";

GRANT SELECT ON TABLE "finance"."pool_settlements" TO "authenticated";

GRANT SELECT ON TABLE "finance"."reward_codes" TO "authenticated";

GRANT SELECT ON TABLE "finance"."reward_pools" TO "anon", "authenticated";

GRANT SELECT ON TABLE "market"."budget_alerts" TO "authenticated";

GRANT SELECT ON TABLE "market"."campaign_assets" TO "anon", "authenticated";

GRANT SELECT ON TABLE "market"."campaign_invites" TO "authenticated";

GRANT SELECT ON TABLE "market"."campaigns" TO "anon", "authenticated";

GRANT SELECT ON TABLE "market"."categories" TO "anon", "authenticated";

GRANT SELECT ON TABLE "market"."claims" TO "authenticated";

GRANT SELECT ("accepted_at") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("accepted_by") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("created_at") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("created_by") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("expires_at") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("id") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("org_id") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ("role") ON TABLE "market"."org_invites" TO "authenticated";

GRANT SELECT ON TABLE "market"."org_links" TO "authenticated";

GRANT SELECT ON TABLE "market"."org_members" TO "authenticated";

GRANT SELECT ON TABLE "market"."organizations" TO "authenticated";

GRANT SELECT ("avatar_path") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ("created_at") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ("display_name") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ("id") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ("username") ON TABLE "market"."profiles" TO "anon";

GRANT SELECT ON TABLE "market"."profiles" TO "authenticated";

GRANT SELECT ON TABLE "market"."rate_rules" TO "anon", "authenticated";

GRANT SELECT ON TABLE "market"."referrals" TO "authenticated";

GRANT SELECT ("campaign_id") ON TABLE "market"."report_links" TO "authenticated";

GRANT SELECT ("created_at") ON TABLE "market"."report_links" TO "authenticated";

GRANT SELECT ("created_by") ON TABLE "market"."report_links" TO "authenticated";

GRANT SELECT ("expires_at") ON TABLE "market"."report_links" TO "authenticated";

GRANT SELECT ("id") ON TABLE "market"."report_links" TO "authenticated";

GRANT SELECT ("revoked_at") ON TABLE "market"."report_links" TO "authenticated";

GRANT SELECT ("code") ON TABLE "market"."reward_types" TO "anon";

GRANT SELECT ("created_at") ON TABLE "market"."reward_types" TO "anon";

GRANT SELECT ("decimals") ON TABLE "market"."reward_types" TO "anon";

GRANT SELECT ("fulfillment") ON TABLE "market"."reward_types" TO "anon";

GRANT SELECT ("idr_value_per_unit") ON TABLE "market"."reward_types" TO "anon";

GRANT SELECT ("id") ON TABLE "market"."reward_types" TO "anon";

GRANT SELECT ("kind") ON TABLE "market"."reward_types" TO "anon";

GRANT SELECT ("name") ON TABLE "market"."reward_types" TO "anon";

GRANT SELECT ("owner_org_id") ON TABLE "market"."reward_types" TO "anon";

GRANT SELECT ("recipient_schema") ON TABLE "market"."reward_types" TO "anon";

GRANT SELECT ("stock") ON TABLE "market"."reward_types" TO "anon";

GRANT SELECT ("unit_label") ON TABLE "market"."reward_types" TO "anon";

GRANT SELECT ("code") ON TABLE "market"."reward_types" TO "authenticated";

GRANT SELECT ("created_at") ON TABLE "market"."reward_types" TO "authenticated";

GRANT SELECT ("decimals") ON TABLE "market"."reward_types" TO "authenticated";

GRANT SELECT ("fulfillment") ON TABLE "market"."reward_types" TO "authenticated";

GRANT SELECT ("idr_value_per_unit") ON TABLE "market"."reward_types" TO "authenticated";

GRANT SELECT ("id") ON TABLE "market"."reward_types" TO "authenticated";

GRANT SELECT ("kind") ON TABLE "market"."reward_types" TO "authenticated";

GRANT SELECT ("name") ON TABLE "market"."reward_types" TO "authenticated";

GRANT SELECT ("owner_org_id") ON TABLE "market"."reward_types" TO "authenticated";

GRANT SELECT ("recipient_schema") ON TABLE "market"."reward_types" TO "authenticated";

GRANT SELECT ("stock") ON TABLE "market"."reward_types" TO "authenticated";

GRANT SELECT ("unit_label") ON TABLE "market"."reward_types" TO "authenticated";

GRANT SELECT ON TABLE "ops"."alerts" TO "authenticated";

GRANT SELECT ON TABLE "ops"."audit_logs" TO "authenticated";

GRANT SELECT ON TABLE "ops"."broadcasts" TO "authenticated";

GRANT UPDATE ("email_promotions") ON TABLE "ops"."notification_prefs" TO "authenticated";

GRANT UPDATE ("updated_at") ON TABLE "ops"."notification_prefs" TO "authenticated";

GRANT INSERT, SELECT ON TABLE "ops"."notification_prefs" TO "authenticated";

GRANT UPDATE ("read_at") ON TABLE "ops"."notifications" TO "authenticated";

GRANT SELECT ON TABLE "ops"."notifications" TO "authenticated";

GRANT SELECT ON TABLE "ops"."settings" TO "anon", "authenticated";

GRANT SELECT ("created_at") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("external_id") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("followers") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("handle") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("id") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("platform_created_at") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("platform") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("status") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("user_id") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ("verified_at") ON TABLE "tracking"."social_accounts" TO "authenticated";

GRANT SELECT ON TABLE "tracking"."submissions" TO "authenticated";

GRANT SELECT ("comments") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("id") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("is_final") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("likes") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("shares") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("submission_id") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("taken_at") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ("views") ON TABLE "tracking"."view_snapshots" TO "authenticated";

GRANT SELECT ON TABLE "trust"."fraud_flags" TO "authenticated";

GRANT SELECT ("actor_id") ON TABLE "trust"."review_decisions" TO "authenticated";

GRANT SELECT ("created_at") ON TABLE "trust"."review_decisions" TO "authenticated";

GRANT SELECT ("decision") ON TABLE "trust"."review_decisions" TO "authenticated";

GRANT SELECT ("id") ON TABLE "trust"."review_decisions" TO "authenticated";

GRANT SELECT ("message") ON TABLE "trust"."review_decisions" TO "authenticated";

GRANT SELECT ("reason_code") ON TABLE "trust"."review_decisions" TO "authenticated";

GRANT SELECT ("target_id") ON TABLE "trust"."review_decisions" TO "authenticated";

GRANT SELECT ("target_type") ON TABLE "trust"."review_decisions" TO "authenticated";

GRANT SELECT ("created_at") ON TABLE "trust"."score_events" TO "authenticated";

GRANT SELECT ("delta") ON TABLE "trust"."score_events" TO "authenticated";

GRANT SELECT ("id") ON TABLE "trust"."score_events" TO "authenticated";

GRANT SELECT ("reason") ON TABLE "trust"."score_events" TO "authenticated";

GRANT SELECT ("user_id") ON TABLE "trust"."score_events" TO "authenticated";

GRANT SELECT ON TABLE "api"."alerts" TO "authenticated";

GRANT SELECT ON TABLE "api"."audit_logs" TO "authenticated";

GRANT SELECT ON TABLE "api"."broadcasts" TO "authenticated";

GRANT SELECT ON TABLE "api"."budget_alerts" TO "authenticated";

GRANT SELECT ON TABLE "api"."campaign_assets" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."campaign_invites" TO "authenticated";

GRANT SELECT ON TABLE "api"."campaigns" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."categories" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."claims" TO "authenticated";

GRANT SELECT ON TABLE "api"."clip_earnings" TO "authenticated";

GRANT SELECT ON TABLE "api"."fee_rules" TO "authenticated";

GRANT SELECT ON TABLE "api"."fraud_flags" TO "authenticated";

GRANT SELECT ON TABLE "api"."fulfillments" TO "authenticated";

GRANT SELECT ON TABLE "api"."invoices" TO "authenticated";

GRANT SELECT ON TABLE "api"."leaderboard" TO "authenticated";

GRANT SELECT ON TABLE "api"."my_profile" TO "authenticated";

GRANT INSERT ("email_promotions"), UPDATE ("email_promotions") ON TABLE "api"."notification_prefs" TO "authenticated";

GRANT UPDATE ("updated_at") ON TABLE "api"."notification_prefs" TO "authenticated";

GRANT INSERT ("user_id") ON TABLE "api"."notification_prefs" TO "authenticated";

GRANT SELECT ON TABLE "api"."notification_prefs" TO "authenticated";

GRANT UPDATE ("read_at") ON TABLE "api"."notifications" TO "authenticated";

GRANT SELECT ON TABLE "api"."notifications" TO "authenticated";

GRANT SELECT ON TABLE "api"."org_invites" TO "authenticated";

GRANT SELECT ON TABLE "api"."org_links" TO "authenticated";

GRANT SELECT ON TABLE "api"."org_members" TO "authenticated";

GRANT SELECT ON TABLE "api"."org_refunds" TO "authenticated";

GRANT SELECT ON TABLE "api"."organizations" TO "authenticated";

GRANT SELECT ON TABLE "api"."payout_batches" TO "authenticated";

GRANT SELECT ON TABLE "api"."payouts" TO "authenticated";

GRANT SELECT ON TABLE "api"."profiles" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."rate_rules" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."referrals" TO "authenticated";

GRANT SELECT ON TABLE "api"."report_links" TO "authenticated";

GRANT SELECT ON TABLE "api"."review_decisions" TO "authenticated";

GRANT SELECT ON TABLE "api"."reward_codes" TO "authenticated";

GRANT SELECT ON TABLE "api"."reward_pools" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."reward_types" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."score_events" TO "authenticated";

GRANT SELECT ON TABLE "api"."settings" TO "anon", "authenticated";

GRANT SELECT ON TABLE "api"."social_accounts" TO "authenticated";

GRANT SELECT ON TABLE "api"."submissions" TO "authenticated";

GRANT SELECT ON TABLE "api"."view_snapshots" TO "authenticated";

GRANT SELECT ON TABLE "api"."wallet_balances" TO "authenticated";

GRANT SELECT ON TABLE "api"."wallet_entries" TO "authenticated";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" REVOKE ALL ON FUNCTIONS FROM PUBLIC;

SELECT cron.schedule_in_database('broadcast-dispatch', '* * * * *', 'select ops.dispatch_broadcasts()', 'postgres', NULL, true);

SELECT cron.schedule_in_database('budget-alerts', '*/30 * * * *', 'select market.run_budget_alerts()', 'postgres', NULL, true);

SELECT cron.schedule_in_database('claim-expiry', '*/10 * * * *', 'select market.run_claim_expiry()', 'postgres', NULL, true);

SELECT cron.schedule_in_database('earning-release', '7 * * * *', 'select finance.release_earnings()', 'postgres', NULL, true);

SELECT cron.schedule_in_database('fulfillment-retry', '*/5 * * * *', 'select ops.invoke_function(''fulfill'')', 'postgres', NULL, true);

SELECT cron.schedule_in_database('leaderboard-refresh', '17 * * * *', 'select market.refresh_leaderboard()', 'postgres', NULL, true);

SELECT cron.schedule_in_database('lifecycle', '*/5 * * * *', 'select market.run_lifecycle()', 'postgres', NULL, true);

SELECT cron.schedule_in_database('notify-drain', '* * * * *', 'select ops.invoke_function(''notify'')', 'postgres', NULL, true);

SELECT cron.schedule_in_database('reconcile-daily', '0 18 * * *', 'select ops.invoke_function(''bridge'', ''{"action":"reconcile_ids"}'')', 'postgres', NULL, true);

SELECT cron.schedule_in_database('referral-bonus', '30 19 * * *', 'select finance.accrue_referral_bonus()', 'postgres', NULL, true);

SELECT cron.schedule_in_database('token-refresh', '0 */6 * * *', 'select ops.invoke_function(''refresh-tokens'')', 'postgres', NULL, true);

SELECT cron.schedule_in_database('track-due', '*/15 * * * *', 'select tracking.enqueue_due_submissions()', 'postgres', NULL, true);

SELECT cron.schedule_in_database('track-worker', '*/5 * * * *', 'select ops.invoke_function(''track-worker'')', 'postgres', NULL, true);

SELECT cron.schedule_in_database('trust-score', '0 19 * * *', 'select trust.recalc_scores()', 'postgres', NULL, true);

SELECT pgmq.create('email');

SELECT pgmq.create('tracking');
