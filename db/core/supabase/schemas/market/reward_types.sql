-- E-07 reward type (§10.1). owner_org_id NULL = global (mis. IDR). Field penerima ber-flag pii disimpan di identity (E-29).
create table market.reward_types (
  id uuid primary key default gen_random_uuid(),
  owner_org_id uuid references market.organizations (id),
  code text not null check (code ~ '^[A-Z0-9_]{2,40}$'),
  name text not null,
  kind text not null check (kind in ('cash', 'in_game', 'voucher_code', 'points', 'physical', 'custom')),
  unit_label text not null,
  idr_value_per_unit numeric(18, 2) not null check (idr_value_per_unit > 0),
  decimals smallint not null default 0 check (decimals between 0 and 6),
  fulfillment text not null check (fulfillment in ('payout', 'manual_export', 'code_pool', 'webhook')),
  recipient_schema jsonb not null default '[]' check (jsonb_typeof(recipient_schema) = 'array'),
  stock numeric(30, 10) check (stock >= 0),
  webhook_url text check (webhook_url ~ '^https://'),
  webhook_secret_ref uuid,
  fulfillment_margin_pct numeric(5, 2) not null default 0 check (fulfillment_margin_pct between 0 and 100),
  created_at timestamptz not null default now(),
  constraint reward_types_code_unique unique nulls not distinct (owner_org_id, code),
  constraint reward_types_cash_is_payout check ((kind = 'cash') = (fulfillment = 'payout')),
  constraint reward_types_webhook_complete check (fulfillment <> 'webhook' or (webhook_url is not null and webhook_secret_ref is not null))
);
create index reward_types_owner_idx on market.reward_types (owner_org_id);

alter table market.reward_types enable row level security;
create policy reward_types_iss on market.reward_types as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy reward_types_public_read on market.reward_types for select to anon, authenticated using (true);  -- policy:core.public-read
-- webhook_url, webhook_secret_ref, dan margin = konfigurasi internal brand/platform, tidak dibuka ke publik.
grant select (id, owner_org_id, code, name, kind, unit_label, idr_value_per_unit, decimals, fulfillment, recipient_schema, stock,
              created_at) on market.reward_types to anon, authenticated;
