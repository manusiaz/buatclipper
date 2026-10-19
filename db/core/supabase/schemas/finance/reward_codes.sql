-- E-41 pool kode voucher/top-up (F-B03 fulfillment code_pool). Brand mengunggah; satu kode dipasang ke satu fulfillment.
-- Clipper hanya melihat kode milik fulfillment-nya; brand pemilik reward type melihat kodenya sendiri.
create table finance.reward_codes (
  id uuid primary key default gen_random_uuid(),
  reward_type_id uuid not null references market.reward_types (id),
  code text not null,
  fulfillment_id uuid references finance.fulfillments (id),
  uploaded_by uuid not null,
  created_at timestamptz not null default now(),
  assigned_at timestamptz,
  constraint reward_codes_unique unique (reward_type_id, code),
  constraint reward_codes_one_per_fulfillment unique (fulfillment_id),
  constraint reward_codes_assignment_complete check ((fulfillment_id is null) = (assigned_at is null))
);
create index reward_codes_available_idx on finance.reward_codes (reward_type_id, created_at) where fulfillment_id is null;

alter table finance.reward_codes enable row level security;
create policy reward_codes_iss on finance.reward_codes as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy reward_codes_own_read on finance.reward_codes for select to authenticated  -- policy:core.rls-self
  using (exists (select 1 from finance.fulfillments f where f.id = fulfillment_id));
create policy reward_codes_owner_org_read on finance.reward_codes for select to authenticated  -- policy:core.org-role
  using (exists (select 1 from market.reward_types rt where rt.id = reward_type_id and rt.owner_org_id is not null
                 and (select ops.is_org_member(rt.owner_org_id, 'brand_owner', 'brand_manager'))));
create policy reward_codes_admin_read on finance.reward_codes for select to authenticated  -- policy:core.admin-aal2
  using ((select ops.has_admin('admin_ops', 'admin_finance')));
grant select on finance.reward_codes to authenticated;
