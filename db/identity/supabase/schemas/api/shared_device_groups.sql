-- FR-05: grup sesi dari IP + user agent yang sama dengan ≥ p_min_accounts akun berbeda. Hanya bridge identity (service role).
create function api.shared_device_groups(p_since interval default '1 day', p_min_accounts int default 3)
returns table (ip inet, user_agent text, user_ids uuid[])
language sql stable security definer set search_path = '' as $$
  select s.ip, s.user_agent, array_agg(distinct s.user_id)
  from auth.sessions s
  where s.created_at > now() - p_since and s.ip is not null
  group by s.ip, s.user_agent
  having count(distinct s.user_id) >= p_min_accounts;
$$;
revoke execute on function api.shared_device_groups(interval, int) from public;
grant execute on function api.shared_device_groups(interval, int) to service_role;
