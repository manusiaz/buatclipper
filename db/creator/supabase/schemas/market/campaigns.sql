-- Replika katalog campaign untuk validasi submit & tracking di creator. Dua sumber: isi dari brand (judul, platform, syarat
-- caption & akun, mode review, batas klip) dan ekonomi/status dari admin (status, deadline, view window). Semua kolom
-- nullable: baris pertama bisa datang dari sumber mana pun (kolom wajib yang belum tiba membuat insert replika dilewati).
create table market.campaigns (
  id uuid primary key,
  -- dari brand
  org_id uuid,
  title text,
  type text,
  platforms market.platform[],
  required_hashtags text[],
  required_mentions text[],
  required_links text[],
  min_duration_sec smallint,
  max_duration_sec smallint,
  review_mode text,
  min_followers integer,
  min_account_age_days smallint,
  max_clips_per_clipper smallint,
  allow_video_reuse boolean,
  -- dari admin
  status market.campaign_status,
  submit_deadline timestamptz,
  view_window_days smallint
);

alter table market.campaigns enable row level security;
create policy campaigns_iss on market.campaigns as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
-- Tanpa policy baca: browser membaca campaign dari admin/brand; di sini hanya fungsi definer (Edge Function creator).

-- Replika claim dari admin (pemilik: kuota & budget dicek di satu transaksi admin). Satu sumber → kolom wajib.
create table market.claims (
  id uuid primary key,
  campaign_id uuid not null,
  user_id uuid not null,
  status market.claim_status not null,
  expires_at timestamptz not null,
  created_at timestamptz not null
);
create index claims_user_idx on market.claims (user_id);

alter table market.claims enable row level security;
create policy claims_iss on market.claims as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy claims_own_read on market.claims for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
grant select on market.claims to authenticated;
