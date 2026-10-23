-- E-11 claim = reservasi 1 slot submit, kedaluwarsa 48 jam (config). Status mengikuti S-02.
-- Maks 1 claim terbuka per campaign per clipper (F-C05) ditegakkan unique index, bukan hanya di claim_campaign.
create table market.claims (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references market.campaigns (id),
  user_id uuid not null references market.profiles (id),
  status market.claim_status not null default 'open',
  expires_at timestamptz not null,
  reminded_at timestamptz,
  created_at timestamptz not null default now(),
  constraint claims_expiry check (expires_at > created_at),
  constraint claims_key unique (id, user_id, campaign_id)
);
create unique index claims_one_open_per_campaign on market.claims (campaign_id, user_id) where status = 'open';
create index claims_user_idx on market.claims (user_id, created_at desc);
create index claims_campaign_idx on market.claims (campaign_id, status);
create index claims_expiring_idx on market.claims (expires_at) where status = 'open';
-- Replika ke creator: submit memeriksa claim terbuka milik sendiri.
create trigger claims_replicate after insert or update or delete on market.claims for each row
  execute function bus.replicate('creator:campaign_id,user_id,status,expires_at,created_at');

alter table market.claims enable row level security;
create policy claims_iss on market.claims as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy claims_own_read on market.claims for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
create policy claims_org_read on market.claims for select to authenticated  -- policy:core.rls-org
  using (exists (select 1 from market.campaigns c where c.id = campaign_id and (select ops.is_org_member(c.org_id))));
create policy claims_admin_read on market.claims for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on market.claims to authenticated;

-- job:claim-expiry — pengingat 6 jam sebelum habis (in-app + email), lalu claim lewat batas → expired (slot dilepas).
create function market.run_claim_expiry() returns void
language plpgsql security definer set search_path = '' as $$
declare
  c record;
begin
  for c in update market.claims set reminded_at = now()
            where status = 'open' and reminded_at is null and expires_at <= now() + interval '6 hours' and expires_at > now()
            returning id, user_id, campaign_id, expires_at loop
    perform ops.enqueue_notification(c.user_id, 'claim.expiring', market.campaign_ref(c.campaign_id)
                                     || jsonb_build_object('claim_id', c.id, 'expires_at', c.expires_at,
                                                           'hours_left', ceil(extract(epoch from c.expires_at - now()) / 3600)::int));
  end loop;
  update market.claims set status = 'expired' where status = 'open' and expires_at <= now();
end $$;
revoke execute on function market.run_claim_expiry() from public;
