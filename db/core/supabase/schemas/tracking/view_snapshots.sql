-- E-13 snapshot metrik per submisi. Append-only; satu snapshot final saat lock. raw = respons API (tidak dibuka ke browser).
-- Error/rate limit API tidak pernah disimpan sebagai 0 views (§11): worker melewatkan snapshot, bukan menulis 0.
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

alter table tracking.view_snapshots enable row level security;
create policy view_snapshots_iss on tracking.view_snapshots as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy view_snapshots_visible on tracking.view_snapshots for select to authenticated  -- policy:core.inherit-parent
  using (exists (select 1 from tracking.submissions s where s.id = submission_id));
grant select (id, submission_id, taken_at, views, likes, comments, shares, is_final) on tracking.view_snapshots to authenticated;
