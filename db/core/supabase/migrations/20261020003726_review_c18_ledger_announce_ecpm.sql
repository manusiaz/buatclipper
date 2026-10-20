SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.worker_retry_later (
  p_queue      text,
  p_msg_id     bigint,
  p_seconds    integer,
  p_submission uuid    DEFAULT NULL::uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  sec int := least(greatest(coalesce(p_seconds, 300), 1), 21600);
begin
  if p_queue is null or p_queue not in ('tracking', 'email') then
    raise exception 'invalid:queue' using errcode = 'P0001';
  end if;
  perform pgmq.set_vt(p_queue, p_msg_id, sec);
  if p_submission is not null then
    update tracking.submissions set retry_after = greatest(coalesce(retry_after, now()), now() + make_interval(secs => sec + 3600))
     where id = p_submission;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION market.campaign_report (
  p_campaign uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
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
                                   order by s.counted_views desc limit 10) t), '[]'::jsonb),
      -- eCPM delivered (§3 metrik) = total bayar brand ÷ (views valid ÷ 1.000): nilai Rupiah semua pool yang terpakai
      -- (non-tunai pakai nilai Rp per unit) + fee manajemen & admin yang benar-benar ditagih (invoice campaign/top-up lunas),
      -- diprorata ke bagian budget yang terpakai; tanpa pajak. Fee rule yang berubah belakangan tidak mengubah angka lama.
      'spent_idr', trim_scale(round(x.spent, 2)),
      'ecpm_idr', case when x.views > 0 then trim_scale(round((x.spent + case when x.budget > 0 then x.fees * x.spent / x.budget else 0 end)
                                                             / x.views * 1000, 2)) end)
    from market.campaigns c
    cross join lateral (select coalesce(sum(p.allocated * rt.idr_value_per_unit), 0) as spent,
                               coalesce(sum(p.total * rt.idr_value_per_unit), 0) as budget,
                               coalesce((select sum(i.mgmt_fee + i.admin_fee) from finance.invoices i
                                          where i.campaign_id = c.id and i.kind in ('campaign', 'topup') and i.status = 'paid'), 0) as fees,
                               coalesce((select sum(s.counted_views) from tracking.submissions s
                                          where s.campaign_id = c.id and s.status = any (counted)), 0) as views
                          from finance.reward_pools p join market.reward_types rt on rt.id = p.reward_type_id
                         where p.campaign_id = c.id) x
   where c.id = p_campaign);
end $function$;

CREATE INDEX ledger_entries_ref_idx ON finance.ledger_entries USING btree (ref_id text_pattern_ops);

CREATE INDEX notifications_campaign_new_idx ON ops.notifications USING btree (user_id, ((payload ->> 'campaign_id'::text)))
  WHERE (EVENT = 'campaign.new'::text);
