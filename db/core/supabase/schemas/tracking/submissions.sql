-- E-12 submisi video. Isi (video, akun, review_route, snapshot terakhir) = replika project creator (ditulis creator/social
-- setelah validasi API platform). Milik admin: status (S-03), counted_views, locked_at, next_poll_at (jadwal poll §11, dibaca
-- creator/track-worker) — direplika ke creator. Submisi baru (validating) diputus bus_in.tracking_submissions_applied.
-- user_id & campaign_id dikunci FK komposit ke claim (milik admin), supaya RLS cepat dan tidak bisa beda dari claim-nya.
create table tracking.submissions (
  id uuid primary key default gen_random_uuid(),  -- default hanya untuk fixture uji; replika membawa id creator
  claim_id uuid not null,
  user_id uuid not null,
  campaign_id uuid not null,
  social_account_id uuid not null,
  platform market.platform not null,
  post_id text not null,
  url text not null check (url ~ '^https://'),
  posted_at timestamptz not null,
  duration_sec integer,  -- dari API platform saat submit; null = tidak diketahui (campaign berbatas durasi → wajib review manual)
  review_route text not null default 'manual' check (review_route in ('auto', 'manual')),  -- keputusan creator saat submit
  status tracking.submission_status not null default 'validating',
  counted_views bigint not null default 0 check (counted_views >= 0),
  last_snapshot_at timestamptz,
  last_views bigint check (last_views >= 0),  -- views snapshot terakhir apa adanya (F-C07); counted_views = yang dihitung earning
  -- snapshot terakhir yang selesai diproses tracking.apply_snapshot (fraud + accrual) — milik admin, satu-satunya penulis;
  -- last_snapshot_at/last_views milik creator (replika, ikut tiba walau hook snapshot gagal → bukan bukti diproses, CL15/CX12)
  applied_snapshot_id bigint,
  final_skipped boolean not null default false,  -- snapshot final dilewati admin_ops (api.skip_failed_snapshot): lock tanpa accrual-nya
  next_poll_at timestamptz,
  cover_hash bigint,  -- FR-07: dHash 64-bit cover saat submit (perseptual; null = cover tidak terbaca)
  locked_at timestamptz,
  created_at timestamptz not null default now(),
  constraint submissions_one_per_claim unique (claim_id),
  constraint submissions_claim_fk foreign key (claim_id, user_id, campaign_id)
    references market.claims (id, user_id, campaign_id),
  constraint submissions_account_fk foreign key (social_account_id, user_id, platform)
    references tracking.social_accounts (id, user_id, platform),
  constraint submissions_one_post_per_campaign unique (campaign_id, platform, post_id),
  constraint submissions_locked_has_time check (status not in ('locked', 'settled') or locked_at is not null)
);
create index submissions_user_idx on tracking.submissions (user_id, created_at desc);
create index submissions_campaign_idx on tracking.submissions (campaign_id, status);
create index submissions_post_idx on tracking.submissions (platform, post_id);
create index submissions_account_idx on tracking.submissions (social_account_id, user_id, platform);
create index submissions_due_idx on tracking.submissions (next_poll_at) where status in ('tracking', 'flagged');
create index submissions_cover_idx on tracking.submissions (created_at) where cover_hash is not null;
create trigger submissions_replicate after insert or update or delete on tracking.submissions for each row
  execute function bus.replicate('creator:status,counted_views,locked_at,next_poll_at');

alter table tracking.submissions enable row level security;
create policy submissions_iss on tracking.submissions as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy submissions_own_read on tracking.submissions for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
create policy submissions_org_read on tracking.submissions for select to authenticated  -- policy:core.rls-org
  using (exists (select 1 from market.campaigns c where c.id = campaign_id and (select ops.is_org_member(c.org_id))));
create policy submissions_admin_read on tracking.submissions for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on tracking.submissions to authenticated;

-- F-A01/F-X01 kesehatan tracking: submisi macet = jadwal poll lewat > 2 jam untuk akun yang masih verified. Jadwal hanya maju
-- saat snapshot tercatat (hook replika snapshot), jadi worker creator mati / antrean macet terlihat di sini (AA-6); lease antrean
-- ada di creator.
create function tracking.lagging_count() returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from tracking.submissions s join tracking.social_accounts a on a.id = s.social_account_id and a.status = 'verified'
   where s.status in ('tracking', 'flagged') and s.next_poll_at < now() - interval '2 hours';
$$;
revoke execute on function tracking.lagging_count() from public;
