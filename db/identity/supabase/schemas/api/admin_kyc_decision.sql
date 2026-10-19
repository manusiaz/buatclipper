-- Reviewer KYC (admin_moderator, aal2) menyetujui/menolak KYC yang menunggu. Notifikasi & catatan tanpa PII di core
-- dikirim app admin lewat core.record_review (§6 J-A2).
create function api.admin_kyc_decision(p_user_id uuid, p_decision member.kyc_status, p_reason text default null)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not member.is_admin('admin_moderator') then
    raise exception 'butuh admin_moderator + aal2' using errcode = '42501';
  end if;
  if p_decision = 'pending' then
    raise exception 'keputusan harus approved atau rejected' using errcode = '22023';
  end if;
  update member.kyc_records
     set status = p_decision,
         reject_reason = case when p_decision = 'rejected' then p_reason end,
         decided_at = now(),
         decided_by = (select auth.uid())
   where user_id = p_user_id and status = 'pending';
  if not found then
    raise exception 'tidak ada KYC menunggu untuk user ini' using errcode = 'P0002';
  end if;
  insert into member.audit_logs (actor_id, action, target, after)
  values ((select auth.uid()), 'kyc.decide', 'user:' || p_user_id,
          jsonb_build_object('status', p_decision, 'reason', p_reason));
end $$;
revoke execute on function api.admin_kyc_decision(uuid, member.kyc_status, text) from public;
grant execute on function api.admin_kyc_decision(uuid, member.kyc_status, text) to authenticated;
