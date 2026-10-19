-- E-39 referral (F-C16). Satu clipper hanya bisa direferensikan sekali, dicatat saat profil pertama dibuat dari
-- {domain}/?ref=<kode>. Bonus dibayar platform (jurnal ref_type referral_bonus dari platform_revenue), bukan potong earning
-- teman, dan baru berlaku setelah teman lolos KYC (qualified_at) sampai bonus_until.
create table market.referrals (
  referred_id uuid primary key references market.profiles (id),
  referrer_id uuid not null references market.profiles (id),
  code text not null,
  qualified_at timestamptz,
  bonus_until timestamptz,
  created_at timestamptz not null default now(),
  constraint referrals_not_self check (referrer_id <> referred_id),
  constraint referrals_bonus_after_qualified check (bonus_until is null or qualified_at is not null)
);
create index referrals_referrer_idx on market.referrals (referrer_id);

alter table market.referrals enable row level security;
create policy referrals_iss on market.referrals as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy referrals_referrer_read on market.referrals for select to authenticated using (referrer_id = (select auth.uid()));  -- policy:core.rls-self
create policy referrals_admin_read on market.referrals for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on market.referrals to authenticated;

-- Kode referral milik sendiri; dibuat saat pertama diminta.
create function api.my_referral_code() returns text
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  code text;
begin
  if uid is null or not ops.iss_ok() then
    raise exception 'butuh sesi identity' using errcode = '42501';
  end if;
  select p.referral_code into code from market.profiles p where p.id = uid;
  while code is null loop
    begin
      update market.profiles set referral_code = substr(md5(extensions.gen_random_bytes(16)::text), 1, 8)
       where id = uid returning referral_code into code;
      if not found then
        raise exception 'profil belum ada' using errcode = 'P0002';
      end if;
    exception when unique_violation then
      code := null;
    end;
  end loop;
  return code;
end $$;
revoke execute on function api.my_referral_code() from public;
grant execute on function api.my_referral_code() to authenticated;
