SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.campaign_detail (
  p_campaign uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  staff boolean;
  chk record;
  bud jsonb;
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null or not market.campaign_visible(c) then
    perform market.fail('not_found:campaign', 'campaign tidak ada atau tidak terlihat', 'P0002');
  end if;
  staff := ops.is_org_member(c.org_id) or ops.has_admin();
  select * into chk from market.claim_check(c.id);
  bud := market.campaign_budget(c.id);
  return jsonb_build_object(
    'campaign', (select to_jsonb(v) from (select c.id, c.org_id, c.slug, c.title, c.type, c.category_id, c.status, c.platforms,
                   c.brief, c.required_hashtags, c.required_mentions, c.required_links, c.sponsored_label, c.min_duration_sec,
                   c.max_duration_sec, c.dos, c.donts, c.example_urls, c.faq, c.service_mode, c.start_at, c.submit_deadline,
                   c.view_window_days, c.review_mode, c.min_followers, c.min_account_age_days, c.min_trust_score, c.kyc_required,
                   c.min_views, c.max_clips_per_clipper, c.clipper_quota, c.allow_video_reuse, c.visibility, c.is_template,
                   c.pinned_until, c.pinned_rank, c.created_at, c.fee_rule_id,
                   case when staff then c.managed_brief end as managed_brief) v),
    'brand', (select jsonb_build_object('name', o.name, 'verified', o.status = 'verified') from market.organizations o
               where o.id = c.org_id),
    'rules', bud -> 'rates',
    'pools', bud -> 'pools',
    'budget_idr', bud -> 'budget_idr',
    'remaining_idr', bud -> 'remaining_idr',
    'est_remaining_views', bud -> 'est_remaining_views',
    -- Potongan earning clipper (E-21) yang berlaku untuk campaign ini; dipotong saat Rupiah Tertunda → Tersedia.
    'clipper_fee_pct', coalesce((finance.effective_fee_rule(c.org_id, c.id)).clipper_fee_pct, 0),
    'assets', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', a.id, 'kind', a.kind, 'audience', a.audience, 'url', a.url, 'size_bytes', a.size_bytes,
                  'storage_path', a.storage_path,
                  'bucket', case when a.storage_path is null then null when a.kind = 'cover' then 'campaign-covers' else 'campaign-assets' end)
                  order by a.kind = 'cover' desc, a.created_at, a.id)
                from market.campaign_assets a where a.campaign_id = c.id and (a.audience = 'clipper' or staff)), '[]'::jsonb),
    'my', jsonb_build_object(
      'claim', (select jsonb_build_object('id', cl.id, 'status', cl.status, 'expires_at', cl.expires_at, 'created_at', cl.created_at)
                  from market.claims cl where cl.campaign_id = c.id and cl.user_id = uid
                 order by cl.created_at desc, cl.id limit 1),
      'submissions', coalesce((select jsonb_agg(jsonb_build_object(
                         'id', s.id, 'status', s.status, 'platform', s.platform, 'url', s.url, 'counted_views', s.counted_views,
                         'last_snapshot_at', s.last_snapshot_at, 'created_at', s.created_at,
                         'review', (select jsonb_build_object('decision', d.decision, 'reason_code', d.reason_code, 'message', d.message,
                                                              'at', d.created_at)
                                      from trust.review_decisions d
                                     where d.target_type = 'submission' and d.target_id = s.id and d.decision <> 'appeal'
                                     order by d.created_at desc, d.id desc limit 1),
                         'appeal_used', exists (select 1 from trust.review_decisions d where d.target_type = 'submission'
                                                and d.target_id = s.id and d.decision = 'appeal'))
                         order by s.created_at desc)
                       from tracking.submissions s where s.campaign_id = c.id and s.user_id = uid), '[]'::jsonb),
      'clips_used', (select count(*) from tracking.submissions s where s.campaign_id = c.id and s.user_id = uid
                     and s.status not in ('rejected', 'rejected_final'))),
    'cta_state', chk.state,
    'cta_reason', chk.reason);
end $function$;

CREATE OR REPLACE FUNCTION api.worker_fulfillments_due (
  p_limit integer
)
  RETURNS TABLE (
    id             uuid,
    user_id        uuid,
    reward_type_id uuid,
    amount         numeric,
    recipient      jsonb,
    fulfillment    text,
    webhook_url    text,
    webhook_secret text,
    attempts       smallint
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
#variable_conflict use_column
begin
  return query
  with due as (
    select f.id as fid from finance.fulfillments f join market.reward_types rt on rt.id = f.reward_type_id
     where (f.status = 'requested'
            -- pool kode sempat kosong: lanjut otomatis begitu ada kode bebas lagi (S-06 on_hold → processing)
            -- (atau kodenya sudah terpasang tapi hasil kirim belum tercatat: worker mati di tengah jalan)
            or (f.status = 'on_hold' and f.last_error = 'code_pool_empty' and rt.fulfillment = 'code_pool'
                and exists (select 1 from finance.reward_codes rc where rc.reward_type_id = f.reward_type_id
                             and (rc.fulfillment_id is null or rc.fulfillment_id = f.id))))
       and rt.fulfillment in ('code_pool', 'webhook')
       and (f.next_retry_at is null or f.next_retry_at <= now())
     order by coalesce(f.next_retry_at, f.created_at), f.id
     limit greatest(coalesce(p_limit, 20), 1)
     for update of f skip locked),
  upd as (
    -- Lease lama masih terisi = worker sebelumnya mati sebelum mencatat hasil: kiriman itu mungkin sudah sampai ke brand.
    update finance.fulfillments f set next_retry_at = now() + interval '5 minutes', leased_until = now() + interval '5 minutes',
           delivery_uncertain = f.delivery_uncertain or f.leased_until is not null
      from due where f.id = due.fid
    returning f.id as fid, f.user_id as uid, f.reward_type_id as rtid, f.amount as amt, f.recipient as rcp, f.attempts as att)
  select upd.fid, upd.uid, upd.rtid, upd.amt::numeric, upd.rcp, rt.fulfillment, rt.webhook_url,
         (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.id = rt.webhook_secret_ref), upd.att
    from upd join market.reward_types rt on rt.id = upd.rtid;
end $function$;
