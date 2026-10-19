-- E-40 riwayat perubahan Trust Score (F-C12, §12): naik dari submisi approved & umur akun bersih, turun dari reject,
-- fraud flag, banding gagal. Append-only; E-01.trust_score = 50 + jumlah delta (dibatasi 0–100), dihitung ulang job trust-score.
create table trust.score_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references market.profiles (id),
  delta smallint not null check (delta <> 0 and delta between -100 and 100),
  reason text not null check (reason in ('submission_approved', 'clean_tenure', 'submission_rejected', 'fraud_flag',
                                         'appeal_failed', 'admin_override')),
  ref_id text,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint score_events_override_has_actor check (reason <> 'admin_override' or created_by is not null)
);
create index score_events_user_idx on trust.score_events (user_id, created_at desc);
create trigger score_events_append_only before update or delete on trust.score_events
  for each row execute function ops.reject_mutation();

alter table trust.score_events enable row level security;
create policy score_events_iss on trust.score_events as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy score_events_own_read on trust.score_events for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
create policy score_events_admin_read on trust.score_events for select to authenticated  -- policy:core.admin-aal2
  using ((select ops.has_admin('admin_moderator', 'admin_support')));
grant select (id, user_id, delta, reason, created_at) on trust.score_events to authenticated;
