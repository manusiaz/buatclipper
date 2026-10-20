-- E-03 anggota org + role brand. Ditulis create_org (pemilik), accept_org_invite (undangan), dan manage_org (admin, paket managed). Org selalu punya ≥ 1 brand_owner.
create table market.org_members (
  org_id uuid not null references market.organizations (id),
  user_id uuid not null references market.profiles (id),
  role market.org_role not null,
  added_by uuid,
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index org_members_user_idx on market.org_members (user_id);

create function market.keep_one_owner() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.role = 'brand_owner' and (tg_op = 'DELETE' or new.role <> 'brand_owner')
     and not exists (select 1 from market.org_members m
                     where m.org_id = old.org_id and m.role = 'brand_owner' and m.user_id <> old.user_id) then
    raise exception 'org harus punya minimal satu brand_owner' using errcode = '23514';
  end if;
  return coalesce(new, old);
end $$;
create trigger org_members_keep_owner before update or delete on market.org_members
  for each row execute function market.keep_one_owner();

-- Owner yang dikeluarkan/diturunkan lewat jalur mana pun (manage_team, admin manage_org add_member, tutup akun): link undangan
-- belum dipakai yang ia buat dicabut, supaya tidak jadi jalan kembali (R23-1, R24-2).
create function market.revoke_owner_invites() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.role = 'brand_owner' and (tg_op = 'DELETE' or new.role <> 'brand_owner') then
    delete from market.org_invites where org_id = old.org_id and created_by = old.user_id and accepted_at is null;
  end if;
  return null;
end $$;
create trigger org_members_revoke_owner_invites after update or delete on market.org_members
  for each row execute function market.revoke_owner_invites();

alter table market.org_members enable row level security;
create policy org_members_iss on market.org_members as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy org_members_same_org_read on market.org_members for select to authenticated using ((select ops.is_org_member(org_id)));  -- policy:core.rls-org
create policy org_members_admin_read on market.org_members for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on market.org_members to authenticated;
