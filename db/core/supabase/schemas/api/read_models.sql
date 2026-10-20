-- Read model untuk UI (stable, security definer dengan cek visibilitas = RLS campaigns lewat market.campaign_visible).

-- F-C04 detail campaign + status claim/submisi pemanggil + CTA (sama dengan list_campaigns & claim_campaign).
-- Aset: path storage (bucket campaign-covers untuk cover, campaign-assets lainnya; UI membuat signed URL); berkas internal
-- hanya untuk anggota org & admin.
create function api.campaign_detail(p_campaign uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
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
end $$;

-- F-B05/F-B08 dashboard brand: angka laporan (market.campaign_report, sama dengan link read-only) + spend per pool, eCPM,
-- utilisasi, proyeksi, kurva views harian (selisih antar snapshot, tanggal WIB). Anggota org (role apa pun) atau admin.
create function api.campaign_stats(p_campaign uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  rep jsonb;
  bud jsonb;
  proj jsonb;
  views numeric;
  counted constant tracking.submission_status[] := array['tracking', 'flagged', 'locked', 'settled']::tracking.submission_status[];
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not (ops.is_org_member(c.org_id) or ops.has_admin()) then
    perform market.fail('auth:forbidden', 'dashboard hanya untuk anggota org', '42501');
  end if;
  rep := market.campaign_report(c.id);
  bud := market.campaign_budget(c.id);
  proj := market.campaign_projection(c.id);
  views := (rep ->> 'views_valid')::numeric;
  return rep || jsonb_build_object(
    'pools', bud -> 'pools',
    'est_remaining_views', bud -> 'est_remaining_views',
    'budget_idr', proj -> 'budget_idr',
    'spent_idr', proj -> 'spent_idr',
    'remaining_idr', proj -> 'remaining_idr',
    'utilization_pct', proj -> 'utilization_pct',
    'projection', proj,
    'daily', coalesce((select jsonb_agg(jsonb_build_object('day', d.day, 'views', d.views) order by d.day)
                         from (select (x.taken_at at time zone 'Asia/Jakarta')::date as day, sum(x.delta) as views
                                 from (select vs.taken_at,
                                              vs.views - coalesce(lag(vs.views) over (partition by vs.submission_id order by vs.taken_at), 0) as delta
                                         from tracking.view_snapshots vs join tracking.submissions s on s.id = vs.submission_id
                                        where s.campaign_id = c.id and s.status = any (counted)) x
                                group by 1) d), '[]'::jsonb));
end $$;

-- F-C12 profil clipper: total views valid, klip, approval rate (approved ÷ diputus; yang menunggu/banding tidak dihitung),
-- earning per reward type per bucket S-04 dari ledger, Trust Score.
create function api.my_stats() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  approved int;
  rejected int;
begin
  select count(*) filter (where s.status in ('tracking', 'flagged', 'forfeited', 'locked', 'settled')),
         count(*) filter (where s.status in ('rejected', 'rejected_final'))
    into approved, rejected
    from tracking.submissions s where s.user_id = uid;
  return jsonb_build_object(
    'trust_score', (select p.trust_score from market.profiles p where p.id = uid),
    'status', (select p.status from market.profiles p where p.id = uid),
    'total_views', coalesce((select sum(s.counted_views) from tracking.submissions s where s.user_id = uid
                             and s.status in ('tracking', 'flagged', 'locked', 'settled')), 0),
    'clips', (select count(*) from tracking.submissions s where s.user_id = uid),
    'campaigns', (select count(distinct s.campaign_id) from tracking.submissions s where s.user_id = uid),
    'approved', approved,
    'rejected', rejected,
    'approval_rate', case when approved + rejected > 0 then round(approved::numeric / (approved + rejected) * 100, 1) end,
    'earnings', coalesce((select jsonb_agg(jsonb_build_object('reward_type_id', x.reward_type_id, 'code', rt.code,
                                                              'unit_label', rt.unit_label, 'decimals', rt.decimals,
                                                              'pending', trim_scale(x.pending), 'available', trim_scale(x.available),
                                                              'withdrawn', trim_scale(x.withdrawn),
                                                              'total', trim_scale(x.pending + x.available + x.withdrawn))
                                           order by rt.code)
                            from (select e.reward_type_id,
                                         coalesce(sum(e.amount) filter (where e.state = 'pending'), 0) as pending,
                                         coalesce(sum(e.amount) filter (where e.state = 'available'), 0) as available,
                                         coalesce(sum(e.amount) filter (where e.state = 'withdrawn'), 0) as withdrawn
                                    from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                                   where a.owner_type = 'user_wallet' and a.owner_id = uid
                                   group by e.reward_type_id) x
                            join market.reward_types rt on rt.id = x.reward_type_id), '[]'::jsonb));
end $$;

revoke execute on function api.campaign_detail(uuid), api.campaign_stats(uuid), api.my_stats() from public;
grant execute on function api.campaign_detail(uuid), api.campaign_stats(uuid), api.my_stats() to authenticated;
