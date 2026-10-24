-- F-A07 antrean KYC (admin_moderator aal2). Tanpa PII: nama & foto KTP dibuka per user lewat api.admin_read (tercatat audit).
create function api.admin_kyc_queue(p_status text default 'pending', p_limit int default 100)
returns table (user_id uuid, status text, submitted_at timestamptz, decided_at timestamptz, reject_reason text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not member.is_admin('admin_moderator') then
    raise exception 'butuh admin_moderator + aal2' using errcode = '42501';
  end if;
  return query
    select k.user_id, k.status::text, k.submitted_at, k.decided_at, k.reject_reason
      from member.kyc_records k
     where k.user_id is not null and k.status = p_status::member.kyc_status
     order by case when k.status = 'pending' then k.submitted_at end, k.decided_at desc
     limit least(greatest(coalesce(p_limit, 100), 1), 500);
end $$;

-- F-A07 daftar admin (admin_super aal2): siapa memegang role apa. Email dari Auth supaya admin bisa dikenali.
create function api.admin_list_roles()
returns table (user_id uuid, email text, roles text[], granted_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not member.is_admin('admin_super') then
    raise exception 'butuh admin_super + aal2' using errcode = '42501';
  end if;
  return query
    select pr.user_id, u.email::text, array_agg(pr.role::text order by pr.role::text), min(pr.granted_at)
      from member.platform_roles pr join auth.users u on u.id = pr.user_id
     group by pr.user_id, u.email
     order by u.email;
end $$;

revoke execute on function api.admin_kyc_queue(text, int), api.admin_list_roles() from public;
grant execute on function api.admin_kyc_queue(text, int), api.admin_list_roles() to authenticated;
