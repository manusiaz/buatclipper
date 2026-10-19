-- E-32 kategori campaign (F-A04: Movies, Games, Brand, Music, UGC, …). Dikelola admin lewat api.update_config.
create table market.categories (
  id text primary key check (id ~ '^[a-z0-9-]{2,30}$'),
  name_id text not null,
  name_en text not null,
  sort smallint not null default 0,
  active boolean not null default true
);

alter table market.categories enable row level security;
create policy categories_iss on market.categories as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy categories_public_read on market.categories for select to anon, authenticated using (active);  -- policy:core.public-read
create policy categories_admin_read on market.categories for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on market.categories to anon, authenticated;
