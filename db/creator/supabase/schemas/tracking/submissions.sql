-- E-12 submisi video. Pemilik isi: project creator (ditulis Edge Function creator/social setelah validasi API platform).
-- Kolom milik admin (replika): status (S-03: review, fraud, lock), counted_views, locked_at, next_poll_at (jadwal poll §11
-- dihitung admin tiap snapshot). Milik creator: isi video, review_route (auto/manual saat submit), snapshot terakhir, dan
-- lease_until/retry_after (antrean poll lokal). Kunci video = (platform, post_id); video sama ke campaign yang sama selalu
-- ditolak, ke campaign lain hanya kalau allow_video_reuse (dicek api.worker_create_submission).
create table tracking.submissions (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null,
  user_id uuid not null references market.profiles (id),
  campaign_id uuid not null,
  social_account_id uuid not null,
  platform market.platform not null,
  post_id text not null,
  url text not null check (url ~ '^https://'),
  posted_at timestamptz not null,
  duration_sec integer,
  review_route text not null check (review_route in ('auto', 'manual')),
  cover_hash bigint,
  last_snapshot_at timestamptz,
  last_views bigint check (last_views >= 0),
  lease_until timestamptz,  -- enqueue_due_submissions: pesan poll sudah di antrean / ditunda worker_defer
  retry_after timestamptz,  -- §11 backoff: API gagal/rate limit → tidak diantre ulang sebelum waktu ini
  created_at timestamptz not null default now(),
  -- milik admin (replika)
  status tracking.submission_status not null default 'validating',
  counted_views bigint not null default 0,
  locked_at timestamptz,
  next_poll_at timestamptz,
  constraint submissions_one_per_claim unique (claim_id),
  constraint submissions_account_fk foreign key (social_account_id, user_id, platform)
    references tracking.social_accounts (id, user_id, platform),
  constraint submissions_one_post_per_campaign unique (campaign_id, platform, post_id)
);
create index submissions_user_idx on tracking.submissions (user_id, created_at desc);
create index submissions_campaign_idx on tracking.submissions (campaign_id, user_id);
create index submissions_post_idx on tracking.submissions (platform, post_id);
create index submissions_account_idx on tracking.submissions (social_account_id, user_id, platform);
create index submissions_due_idx on tracking.submissions (next_poll_at) where status in ('tracking', 'flagged');
create trigger submissions_replicate after insert or update or delete on tracking.submissions for each row
  execute function bus.replicate('admin:claim_id,user_id,campaign_id,social_account_id,platform,post_id,url,posted_at,duration_sec,review_route,cover_hash,last_snapshot_at,last_views,created_at');

alter table tracking.submissions enable row level security;
create policy submissions_iss on tracking.submissions as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy submissions_own_read on tracking.submissions for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
grant select on tracking.submissions to authenticated;

-- E-13 snapshot metrik per submisi. Append-only; satu snapshot final saat lock. raw = respons API + caption + extra (sinyal
-- fraud di admin; tidak dibuka ke browser). Error/rate limit API tidak pernah disimpan sebagai 0 views (§11).
-- Direplika utuh ke admin: hook di sana menjalankan fraud, accrual, lock, dan jadwal poll berikutnya.
create table tracking.view_snapshots (
  id bigint generated always as identity primary key,
  submission_id uuid not null references tracking.submissions (id),
  taken_at timestamptz not null default now(),
  views bigint not null check (views >= 0),
  likes bigint check (likes >= 0),
  comments bigint check (comments >= 0),
  shares bigint check (shares >= 0),
  is_final boolean not null default false,
  raw jsonb,
  constraint view_snapshots_unique unique (submission_id, taken_at)
);
create unique index view_snapshots_one_final on tracking.view_snapshots (submission_id) where is_final;
create trigger view_snapshots_append_only before update or delete on tracking.view_snapshots
  for each row execute function ops.reject_mutation();
create trigger view_snapshots_replicate after insert on tracking.view_snapshots for each row
  execute function bus.replicate('admin:submission_id,taken_at,views,likes,comments,shares,is_final,raw');

alter table tracking.view_snapshots enable row level security;
create policy view_snapshots_iss on tracking.view_snapshots as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy view_snapshots_visible on tracking.view_snapshots for select to authenticated  -- policy:core.inherit-parent
  using (exists (select 1 from tracking.submissions s where s.id = submission_id));
grant select (id, submission_id, taken_at, views, likes, comments, shares, is_final) on tracking.view_snapshots to authenticated;
