-- F-B09: link laporan read-only. brand_owner/brand_manager membuat & mencabut; siapa pun yang memegang token bisa membaca
-- angka agregat campaign itu lewat {domain}/r/[token] (apps/web, anon). Tidak ada data clipper selain URL posting publik.
create function api.create_report_link(p_campaign uuid, p_days int default 90) returns text
language plpgsql security definer set search_path = '' as $$
declare
  org uuid;
  tok text;
begin
  if not ops.iss_ok() then
    raise exception 'butuh sesi identity' using errcode = '42501';
  end if;
  select c.org_id into org from market.campaigns c where c.id = p_campaign;
  if org is null or not ops.is_org_member(org, 'brand_owner', 'brand_manager') then
    raise exception 'hanya brand_owner atau brand_manager org ini' using errcode = '42501';
  end if;
  tok := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
  insert into market.report_links (campaign_id, token_hash, created_by, expires_at)
  values (p_campaign, sha256(convert_to(tok, 'UTF8')), (select auth.uid()),
          case when p_days is not null then now() + make_interval(days => p_days) end);
  return tok;
end $$;

create function api.revoke_report_link(p_link uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not ops.iss_ok() then
    raise exception 'butuh sesi identity' using errcode = '42501';
  end if;
  update market.report_links rl set revoked_at = now()
   where rl.id = p_link and rl.revoked_at is null
     and exists (select 1 from market.campaigns c where c.id = rl.campaign_id
                 and ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager'));
  if not found then
    raise exception 'link tidak ada atau bukan milik org-mu' using errcode = '42501';
  end if;
end $$;

-- Angka agregat campaign (views valid, klip, clipper, split platform, budget, top klip). Satu sumber untuk laporan read-only
-- (report_by_token) dan dashboard brand (api.campaign_stats). Internal: tanpa cek akses, pemanggil yang menyaring.
create function market.campaign_report(p_campaign uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  counted constant tracking.submission_status[] := array['tracking', 'flagged', 'locked', 'settled']::tracking.submission_status[];
begin
  return (
    select jsonb_build_object(
      'campaign', jsonb_build_object('title', c.title, 'status', c.status, 'start_at', c.start_at,
                                     'submit_deadline', c.submit_deadline, 'platforms', c.platforms),
      'views_valid', coalesce((select sum(s.counted_views) from tracking.submissions s
                               where s.campaign_id = c.id and s.status = any (counted)), 0),
      'clips', (select count(*) from tracking.submissions s where s.campaign_id = c.id and s.status = any (counted)),
      'clippers', (select count(distinct s.user_id) from tracking.submissions s
                   where s.campaign_id = c.id and s.status = any (counted)),
      'by_platform', coalesce((select jsonb_object_agg(x.platform, x.views)
                               from (select s.platform, sum(s.counted_views) as views from tracking.submissions s
                                     where s.campaign_id = c.id and s.status = any (counted) group by s.platform) x), '{}'::jsonb),
      'budget', coalesce((select jsonb_agg(jsonb_build_object('reward_type', rt.code, 'unit', rt.unit_label, 'decimals', rt.decimals,
                                                              'total', p.total, 'spent', p.allocated))
                          from finance.reward_pools p join market.reward_types rt on rt.id = p.reward_type_id
                          where p.campaign_id = c.id), '[]'::jsonb),
      'top_clips', coalesce((select jsonb_agg(jsonb_build_object('url', t.url, 'platform', t.platform, 'views', t.counted_views))
                             from (select s.url, s.platform, s.counted_views from tracking.submissions s
                                   where s.campaign_id = c.id and s.status = any (counted)
                                   order by s.counted_views desc limit 10) t), '[]'::jsonb))
    from market.campaigns c where c.id = p_campaign);
end $$;
revoke execute on function market.campaign_report(uuid) from public;

create function api.report_by_token(p_token text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  cid uuid;
begin
  select rl.campaign_id into cid from market.report_links rl
   where rl.token_hash = sha256(convert_to(p_token, 'UTF8')) and rl.revoked_at is null
     and (rl.expires_at is null or rl.expires_at > now());
  if cid is null then
    return null;
  end if;
  return market.campaign_report(cid);
end $$;

revoke execute on function api.create_report_link(uuid, int), api.revoke_report_link(uuid), api.report_by_token(text) from public;
grant execute on function api.create_report_link(uuid, int), api.revoke_report_link(uuid) to authenticated;
grant execute on function api.report_by_token(text) to anon, authenticated;
