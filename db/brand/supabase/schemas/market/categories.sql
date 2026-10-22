-- Replika E-32 kategori campaign (pemilik: admin, api.update_config). Dipakai builder & FK campaign.
create table market.categories (
  id text primary key,
  name_id text not null,
  name_en text not null,
  sort smallint not null default 0,
  active boolean not null default true
);

alter table market.categories enable row level security;
create policy categories_iss on market.categories as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy categories_public_read on market.categories for select to anon, authenticated using (active);  -- policy:core.public-read
grant select on market.categories to anon, authenticated;
