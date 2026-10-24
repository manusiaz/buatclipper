-- Admin membaca KYC + rekening tersamar satu user. Setiap pemanggilan tercatat di E-24 (identity).
create function api.admin_read(p_user_id uuid)
returns table (user_id uuid, legal_name text, nik_last4 text, doc_ref text, status member.kyc_status,
               submitted_at timestamptz, payout_methods jsonb)
language plpgsql security definer set search_path = '' as $$
begin
  if not member.is_admin('admin_moderator', 'admin_support', 'admin_finance') then
    raise exception 'butuh role admin + aal2' using errcode = '42501';
  end if;
  insert into member.audit_logs (actor_id, action, target)
  values ((select auth.uid()), 'pii.read', 'user:' || p_user_id);
  return query
    select k.user_id, k.legal_name, k.nik_last4, k.doc_ref, k.status, k.submitted_at,
           (select coalesce(jsonb_agg(jsonb_build_object('id', pm.id, 'bank_code', pm.bank_code,
                                                         'last4', pm.account_last4, 'name', pm.account_name)), '[]'::jsonb)
              from member.payout_methods pm where pm.user_id = p_user_id)
    from member.kyc_records k where k.user_id = p_user_id;
end $$;
revoke execute on function api.admin_read(uuid) from public;
grant execute on function api.admin_read(uuid) to authenticated;
