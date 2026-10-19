-- E-19 keputusan review (campaign, submisi, KYC tanpa PII, org) + banding clipper. Append-only.
-- message = alasan yang dilihat subjek; note = catatan internal moderator (tidak dibuka ke browser).
-- Banding maksimal 1× per submisi (F-C07) ditegakkan unique index.
create table trust.review_decisions (
  id bigint generated always as identity primary key,
  target_type text not null check (target_type in ('campaign', 'submission', 'kyc', 'org')),
  target_id uuid not null,
  actor_id uuid,
  decision text not null check (decision in ('approve', 'reject', 'auto_approve', 'appeal', 'uphold', 'overturn')),
  reason_code text,
  message text,
  note text,
  created_at timestamptz not null default now(),
  constraint review_reject_has_reason check (decision <> 'reject' or reason_code is not null),
  constraint review_appeal_on_submission check (decision <> 'appeal' or target_type = 'submission')
);
create unique index review_one_appeal_per_submission on trust.review_decisions (target_id)
  where target_type = 'submission' and decision = 'appeal';
create index review_target_idx on trust.review_decisions (target_type, target_id, created_at);
create trigger review_decisions_append_only before update or delete on trust.review_decisions
  for each row execute function ops.reject_mutation();

alter table trust.review_decisions enable row level security;
create policy review_decisions_iss on trust.review_decisions as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy review_decisions_subject_read on trust.review_decisions for select to authenticated using (  -- policy:core.inherit-parent
     (target_type = 'submission' and exists (select 1 from tracking.submissions s where s.id = target_id))
  or (target_type = 'campaign' and exists (select 1 from market.campaigns c where c.id = target_id
                                           and (select ops.is_org_member(c.org_id))))
  or (target_type = 'kyc' and target_id = (select auth.uid()))
  or (target_type = 'org' and (select ops.is_org_member(target_id))));
create policy review_decisions_admin_read on trust.review_decisions for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select (id, target_type, target_id, actor_id, decision, reason_code, message, created_at)
  on trust.review_decisions to authenticated;
