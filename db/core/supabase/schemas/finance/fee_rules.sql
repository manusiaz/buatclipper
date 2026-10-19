-- E-21 fee rule (§5). Satu rule global; override per org (E-02.fee_rule_id) atau per campaign (E-06.fee_rule_id, F-A03).
-- Baca: global untuk semua user login, rule org/campaign untuk anggota org-nya, admin semua. Tulis: hanya fungsi admin.
create table finance.fee_rules (
  id uuid primary key default gen_random_uuid(),
  scope text not null check (scope in ('global', 'org', 'campaign')),
  mgmt_fee_pct numeric(5, 2) not null default 15 check (mgmt_fee_pct between 0 and 100),
  admin_fee_pct numeric(5, 2) not null default 5 check (admin_fee_pct between 0 and 100),
  clipper_fee_pct numeric(5, 2) not null default 0 check (clipper_fee_pct between 0 and 100),
  instant_withdraw_fee numeric(18, 2) check (instant_withdraw_fee >= 0),
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index fee_rules_one_global on finance.fee_rules (scope) where scope = 'global';

-- Fee hasil negosiasi org lain tidak boleh terlihat. Dicek lewat fungsi plpgsql supaya file ini tidak bergantung pada file
-- market (organizations & campaigns memegang FK ke tabel ini; policy dengan subquery ke sana = siklus urutan file).
create function finance.fee_rule_visible(p_rule uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  return exists (select 1 from market.organizations o where o.fee_rule_id = p_rule and ops.is_org_member(o.id))
      or exists (select 1 from market.campaigns c where c.fee_rule_id = p_rule and ops.is_org_member(c.org_id));
end $$;
revoke execute on function finance.fee_rule_visible(uuid) from public;
grant execute on function finance.fee_rule_visible(uuid) to authenticated;

alter table finance.fee_rules enable row level security;
create policy fee_rules_iss on finance.fee_rules as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy fee_rules_read on finance.fee_rules for select to authenticated  -- policy:core.inherit-parent
  using (scope = 'global' or finance.fee_rule_visible(id) or (select ops.has_admin()));
grant select on finance.fee_rules to authenticated;
