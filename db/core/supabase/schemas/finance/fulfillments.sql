-- E-18 klaim reward non-tunai. Status mengikuti S-06. recipient = field non-PII (mis. game_user_id, zone_id);
-- alamat/HP ada di identity (E-29), di sini hanya recipient_ref.
create table finance.fulfillments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references market.profiles (id),
  reward_type_id uuid not null references market.reward_types (id),
  amount numeric(30, 10) not null check (amount > 0),
  recipient jsonb not null default '{}' check (jsonb_typeof(recipient) = 'object'),
  recipient_ref uuid,
  status finance.fulfillment_status not null default 'requested',
  delivered_ref text,
  attempts smallint not null default 0 check (attempts >= 0),
  last_error text,
  next_retry_at timestamptz,
  -- Worker fulfill sedang mengirim (code_pool/webhook): selama lease aktif klaim tidak bisa dibatalkan (hasil eksternal belum pasti).
  leased_until timestamptz,
  -- Hasil pengiriman tidak pasti (timeout/putus koneksi/5xx, atau lease habis tanpa hasil): reward mungkin sudah sampai.
  delivery_uncertain boolean not null default false,
  -- manual_export: berkas CSV penerima yang sudah diserahkan ke brand (status processing sejak serah-terima).
  export_ref text,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  delivered_at timestamptz,
  constraint fulfillments_idempotency_unique unique (idempotency_key),
  constraint fulfillments_delivered_complete check (status <> 'delivered' or delivered_at is not null)
);
create index fulfillments_user_idx on finance.fulfillments (user_id, created_at desc);
create index fulfillments_reward_type_idx on finance.fulfillments (reward_type_id, status);
create index fulfillments_retry_idx on finance.fulfillments (next_retry_at) where status = 'processing';

alter table finance.fulfillments enable row level security;
create policy fulfillments_iss on finance.fulfillments as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy fulfillments_own_read on finance.fulfillments for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
create policy fulfillments_admin_read on finance.fulfillments for select to authenticated  -- policy:core.admin-aal2
  using ((select ops.has_admin('admin_finance', 'admin_ops')));
grant select on finance.fulfillments to authenticated;
