SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.store_social_token (
  p_account_id uuid,
  p_token      text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  sid uuid;
  st text;
begin
  select a.token_ref, a.status into sid, st from tracking.social_accounts a where a.id = p_account_id for update;
  if not found then
    raise exception 'akun sosmed % tidak ada', p_account_id using errcode = 'P0002';
  end if;
  -- Akun dicabut (reset admin / izin dicabut) atau diputus hanya hidup lagi lewat sambung ulang pemilik (upsert → verified dulu);
  -- refresh token yang sedang jalan tidak boleh menulis token baru (R34-1).
  if st not in ('verified', 'token_expired') then
    return null;
  end if;
  if sid is null then
    sid := vault.create_secret(p_token, 'social:' || p_account_id::text, 'token OAuth sosmed');
    update tracking.social_accounts set token_ref = sid where id = p_account_id;
  else
    perform vault.update_secret(sid, p_token);
  end if;
  update tracking.social_accounts set status = 'verified', verified_at = now()
   where id = p_account_id and status in ('token_expired', 'verified');
  return sid;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_account_status (
  p_account uuid,
  p_status  text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  a tracking.social_accounts;
  new_status text := case p_status when 'expired' then 'token_expired' when 'revoked' then 'revoked' when 'verified' then 'verified' end;
begin
  if new_status is null then
    raise exception 'invalid:status' using errcode = 'P0001';
  end if;
  select * into a from tracking.social_accounts x where x.id = p_account for update;
  if not found then
    raise exception 'not_found:social_account' using errcode = 'P0002';
  end if;
  -- revoked hanya pulih lewat sambung ulang pemilik (worker_upsert_social_account), bukan refresh yang sedang jalan (R34-1)
  if a.status = 'disconnected' or (new_status = 'verified' and a.status = 'revoked') then
    return;
  end if;
  if new_status = 'verified' then
    update tracking.social_accounts set status = 'verified', verified_at = now() where id = a.id;
    update tracking.submissions set next_poll_at = now()
     where social_account_id = a.id and status in ('tracking', 'flagged') and next_poll_at is null;
  else
    update tracking.social_accounts set status = new_status where id = a.id and status <> new_status;
    if a.status = 'verified' then
      perform ops.enqueue_notification(a.user_id, 'social.token_expired',
                                       jsonb_build_object('account_id', a.id, 'platform', a.platform, 'handle', a.handle));
    end if;
    update tracking.submissions set next_poll_at = null where social_account_id = a.id and status in ('tracking', 'flagged');
  end if;
end $function$;

CREATE OR REPLACE FUNCTION trust.auto_approve_overdue()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  h int := coalesce((select (st.value #>> '{}')::int from ops.settings st where st.key = 'public.market.brand_review_auto_approve_hours'), 72);
  r record;
  n int := 0;
begin
  for r in select s.id from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
            where s.status = 'in_review' and c.review_mode = 'brand' and s.created_at <= now() - make_interval(hours => h)
              and not (c.type = 'music' and s.platform = 'tiktok')  -- §11 sound TikTok wajib diverifikasi manual (R34-2)
            order by s.created_at
            for update of s skip locked loop
    perform trust.apply_submission_decision(r.id, 'auto_approve', null, null, null, 'auto');
    n := n + 1;
  end loop;
  return n;
end $function$;
