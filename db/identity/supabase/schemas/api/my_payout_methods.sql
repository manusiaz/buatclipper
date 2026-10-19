-- Rekening tersamar milik sendiri (withdraw, alur 8): hanya last4 + bank + nama, tidak pernah nomor lengkap.
-- security definer + filter auth.uid() eksplisit: fungsi invoker butuh USAGE schema member, yang sengaja tidak diberikan
-- ke authenticated (tes identity_access membuktikan error "permission denied for schema member").
create function api.my_payout_methods()
returns table (id uuid, kind text, bank_code text, account_last4 text, account_name text, verified_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select pm.id, pm.kind, pm.bank_code, pm.account_last4, pm.account_name, pm.verified_at
  from member.payout_methods pm
  where pm.user_id = (select auth.uid()) and pm.disabled_at is null
  order by pm.created_at;
$$;
revoke execute on function api.my_payout_methods() from public;
grant execute on function api.my_payout_methods() to authenticated;
