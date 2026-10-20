-- E-12 submisi video. Status mengikuti S-03. Ditulis Edge Function core/social (service role) setelah validasi API platform.
-- Kunci video = (platform, post_id), bukan URL (satu video bisa punya banyak bentuk URL). Video sama ke campaign yang sama
-- selalu ditolak; ke campaign lain hanya boleh kalau campaign tujuan allow_video_reuse (dicek fungsi submit).
-- user_id & campaign_id disalin dari claim dan dikunci FK komposit, supaya RLS cepat dan tidak bisa beda dari claim-nya.
create table tracking.submissions (
  id uuid primary key default gen_random_uuid(),
  claim_id uuid not null,
  user_id uuid not null,
  campaign_id uuid not null,
  social_account_id uuid not null,
  platform market.platform not null,
  post_id text not null,
  url text not null check (url ~ '^https://'),
  posted_at timestamptz not null,
  status tracking.submission_status not null default 'validating',
  counted_views bigint not null default 0 check (counted_views >= 0),
  last_snapshot_at timestamptz,
  next_poll_at timestamptz,
  retry_after timestamptz,  -- §11 backoff: API gagal/rate limit → penjadwal tidak mengantre ulang sebelum waktu ini
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

alter table tracking.submissions enable row level security;
create policy submissions_iss on tracking.submissions as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy submissions_own_read on tracking.submissions for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
create policy submissions_org_read on tracking.submissions for select to authenticated  -- policy:core.rls-org
  using (exists (select 1 from market.campaigns c where c.id = campaign_id and (select ops.is_org_member(c.org_id))));
create policy submissions_admin_read on tracking.submissions for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on tracking.submissions to authenticated;

-- job:track-due — tiap 15 menit memasukkan submisi jatuh tempo ke Queue "tracking"; next_poll_at digeser sebagai lease,
-- worker menulis jadwal sebenarnya (4/24/72 jam, §11) setelah snapshot tersimpan.
create function tracking.enqueue_due_submissions(p_limit int default 500) returns int
language plpgsql security definer set search_path = '' as $$
declare
  n int := 0;
  s record;
begin
  for s in update tracking.submissions t set next_poll_at = now() + interval '1 hour'
            where t.id in (select d.id from tracking.submissions d
                           where d.status in ('tracking', 'flagged') and d.next_poll_at <= now()
                             and (d.retry_after is null or d.retry_after <= now())
                           order by d.next_poll_at limit p_limit for update skip locked)
            returning t.id, t.platform loop
    perform pgmq.send('tracking', jsonb_build_object('submission_id', s.id, 'platform', s.platform));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function tracking.enqueue_due_submissions(int) from public;
