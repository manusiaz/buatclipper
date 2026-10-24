SET local check_function_bodies = off;

DROP FUNCTION "api"."worker_retry_later"(text, bigint, integer);

ALTER TABLE "tracking"."submissions"
  ADD COLUMN "retry_after" timestamp WITH time zone;

CREATE OR REPLACE FUNCTION api.campaign_stats (
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
end $function$;

CREATE OR REPLACE FUNCTION api.control_campaign (
  p_campaign uuid,
  p_action   text,
  p_params   jsonb DEFAULT '{}'::jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  prm jsonb := coalesce(p_params, '{}');
  c market.campaigns;
  r market.rate_rules;
  newp jsonb;
  t timestamptz := clock_timestamp();
  new_deadline timestamptz;
  e jsonb;
  items jsonb := '[]';
  sub numeric := 0;
  pl record;
begin
  select * into c from market.campaigns where id = p_campaign for update;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  -- §4: topup = billing (brand_finance) tapi kontrak juga memberi brand_manager.
  if not ops.is_org_member(c.org_id, variadic case when p_action = 'topup'
                                                   then array['brand_owner', 'brand_manager', 'brand_finance']
                                                   else array['brand_owner', 'brand_manager'] end::market.org_role[]) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  if c.is_template then
    perform market.fail('invalid:template', 'template bukan campaign berjalan');
  end if;

  if p_action = 'pause' then
    if c.status <> 'live' then
      perform market.fail('invalid_state:' || c.status, 'hanya campaign live yang bisa dijeda');
    end if;
    update market.campaigns set status = 'paused' where id = c.id;
  elsif p_action = 'resume' then
    if c.status <> 'paused' then
      perform market.fail('invalid_state:' || c.status, 'hanya campaign paused yang bisa dilanjutkan');
    end if;
    if c.submit_deadline <= now() then
      perform market.fail('deadline_passed', 'perpanjang deadline dulu');
    end if;
    update market.campaigns set status = 'live' where id = c.id;
  elsif p_action = 'extend' then
    new_deadline := (prm ->> 'submit_deadline')::timestamptz;
    if c.status not in ('scheduled', 'live', 'paused') then
      perform market.fail('invalid_state:' || c.status, 'perpanjang hanya untuk campaign terjadwal/berjalan');
    end if;
    if new_deadline is null or new_deadline <= greatest(now(), c.submit_deadline) then
      perform market.fail('invalid:submit_deadline', 'deadline baru harus setelah deadline lama');
    end if;
    update market.campaigns set submit_deadline = new_deadline where id = c.id;
  elsif p_action = 'raise_rate' then
    if c.status not in ('scheduled', 'live', 'paused') then
      perform market.fail('invalid_state:' || c.status, 'naikkan rate hanya untuk campaign terjadwal/berjalan');
    end if;
    select * into r from market.rate_rules x
     where x.id = (prm ->> 'rule_id')::uuid and x.campaign_id = c.id and (x.effective_to is null or x.effective_to > now())
       for update;
    if r.id is null then
      perform market.fail('invalid:rule_id', 'rule aktif tidak ditemukan');
    end if;
    newp := prm -> 'params';
    perform market.check_rule_params(r.kind, newp);
    if not (case r.kind
             when 'per_1k_views' then market.jnum(newp -> 'rate') > market.jnum(r.params -> 'rate')
             when 'flat_per_post' then market.jnum(newp -> 'amount') > market.jnum(r.params -> 'amount')
             when 'milestone_bonus' then market.jnum(newp -> 'amount') > market.jnum(r.params -> 'amount')
                                         and market.jnum(newp -> 'threshold') <= market.jnum(r.params -> 'threshold')
             else jsonb_array_length(newp -> 'tiers') = jsonb_array_length(r.params -> 'tiers') and newp <> r.params
                  and not exists (select 1 from generate_series(0, jsonb_array_length(newp -> 'tiers') - 1) i
                                  where market.jnum(newp -> 'tiers' -> i -> 'rate') < market.jnum(r.params -> 'tiers' -> i -> 'rate')
                                     or market.jnum(newp -> 'tiers' -> i -> 'from') <> market.jnum(r.params -> 'tiers' -> i -> 'from')
                                     or market.jnum(newp -> 'tiers' -> i -> 'to') is distinct from market.jnum(r.params -> 'tiers' -> i -> 'to'))
           end) then
      perform market.fail('invalid:rate_not_higher', 'rate baru harus lebih tinggi dari rate lama');
    end if;
    -- Rule lama ditutup, rule baru berlaku untuk views sesudahnya (§10.5).
    update market.rate_rules set effective_to = t where id = r.id;
    insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, platform, params, effective_from, lineage_id)
    values (c.id, r.kind, r.reward_type_id, r.pool_id, r.platform, newp, t, coalesce(r.lineage_id, r.id));
  elsif p_action = 'notify_eligible' then
    -- F-B08 intervensi underspend: kabari clipper eligible yang belum pernah menerima pengumuman campaign ini.
    if c.status <> 'live' then
      perform market.fail('invalid_state:' || c.status, 'kabari clipper hanya untuk campaign berjalan');
    end if;
    perform market.announce_campaign(c.id);
  elsif p_action = 'topup' then
    if c.status not in ('scheduled', 'live', 'paused') then
      perform market.fail('invalid_state:' || c.status, 'top-up hanya untuk campaign terjadwal/berjalan');
    end if;
    if jsonb_typeof(prm -> 'pools') is distinct from 'array' or jsonb_array_length(prm -> 'pools') = 0 then
      perform market.fail('invalid:pools', 'pools [{pool_id, amount}] wajib');
    end if;
    for e in select jsonb_array_elements(prm -> 'pools') loop
      select x.id, rt.idr_value_per_unit into pl from finance.reward_pools x join market.reward_types rt on rt.id = x.reward_type_id
       where x.id = (e ->> 'pool_id')::uuid and x.campaign_id = c.id;
      if pl.id is null or coalesce(market.jnum(e -> 'amount'), 0) <= 0 then
        perform market.fail('invalid:pool', 'pool campaign ini + amount > 0');
      end if;
      items := items || jsonb_build_array(jsonb_build_object('pool_id', pl.id, 'amount', market.jnum(e -> 'amount')));
      sub := sub + market.jnum(e -> 'amount') * pl.idr_value_per_unit;
    end loop;
    perform finance.issue_invoice(c.org_id, c.id, 'topup', sub, 0, null, items);
  elsif p_action = 'end_early' then
    if c.status in ('live', 'paused') then
      update market.campaigns set status = 'tracking' where id = c.id;
    elsif c.status in ('draft', 'in_review', 'scheduled') then
      update market.campaigns set status = 'cancelled' where id = c.id;
      update finance.invoices set status = 'void' where campaign_id = c.id and status = 'issued';
    else
      perform market.fail('invalid_state:' || c.status, 'campaign sudah selesai');
    end if;
    update market.claims set status = 'released' where campaign_id = c.id and status = 'open';
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
end $function$;

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
    update tracking.submissions set retry_after = greatest(coalesce(retry_after, now()), now() + make_interval(secs => sec + 300))
     where id = p_submission;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION market.announce_campaign (
  p_campaign uuid
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  n int;
begin
  select count(ops.enqueue_notification(p.id, 'campaign.new', x.payload)) into n
    from market.campaigns c
    cross join lateral (select jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'campaign_slug', c.slug,
                                                  'org_name', (select o.name from market.organizations o where o.id = c.org_id),
                                                  'platforms', to_jsonb(c.platforms)) as payload) x
    join market.profiles p on p.status = 'active' and p.trust_score >= c.min_trust_score
   where c.id = p_campaign and not c.is_template
     and not exists (select 1 from market.org_members m where m.org_id = c.org_id and m.user_id = p.id)
     and (c.visibility <> 'invite' or exists (select 1 from market.campaign_invites i where i.campaign_id = c.id and i.user_id = p.id))
     -- Sekali per clipper per campaign: diumumkan ulang (F-B08) hanya menjangkau yang baru eligible.
     and not exists (select 1 from ops.notifications n where n.user_id = p.id and n.event = 'campaign.new'
                      and n.payload ->> 'campaign_id' = c.id::text)
     and exists (select 1 from tracking.social_accounts a
                 where a.user_id = p.id and a.status = 'verified' and a.platform = any (c.platforms)
                   and coalesce(a.followers, 0) >= c.min_followers
                   and (c.min_account_age_days = 0
                        or a.platform_created_at <= now() - make_interval(days => c.min_account_age_days)));
  return n;
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
      -- (non-tunai pakai nilai Rp per unit, dasar fee) + fee manajemen & admin dari fee rule campaign; tanpa pajak.
      'spent_idr', trim_scale(round(x.spent, 2)),
      'ecpm_idr', case when x.views > 0 then trim_scale(round(x.spent * (1 + (coalesce(fr.mgmt_fee_pct, 0) + coalesce(fr.admin_fee_pct, 0)) / 100)
                                                             / x.views * 1000, 2)) end)
    from market.campaigns c
    cross join lateral (select coalesce((select sum(p.allocated * rt.idr_value_per_unit) from finance.reward_pools p
                                          join market.reward_types rt on rt.id = p.reward_type_id where p.campaign_id = c.id), 0) as spent,
                               coalesce((select sum(s.counted_views) from tracking.submissions s
                                          where s.campaign_id = c.id and s.status = any (counted)), 0) as views) x
    cross join lateral (select * from finance.effective_fee_rule(c.org_id, c.id)) fr
   where c.id = p_campaign);
end $function$;

CREATE OR REPLACE FUNCTION tracking.enqueue_due_submissions (
  p_limit integer DEFAULT 500
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  n int := 0;
  s record;
begin
  for s in update tracking.submissions t set next_poll_at = now() + interval '1 hour'
            where t.id in (select d.id from tracking.submissions d
                           where d.status in ('tracking', 'flagged') and d.next_poll_at <= now()
                             and (d.retry_after is null or d.retry_after <= now())
                           order by d.next_poll_at limit p_limit for update skip locked)
            returning t.id, t.platform loop
    perform pgmq.send('tracking', jsonb_build_object('submission_id', s.id, 'platform', s.platform));
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE VIEW "api"."admin_ledger" WITH (security_invoker=true) AS  SELECT e.id,
    e.txn_id,
    e.created_at,
    a.owner_type,
    a.owner_id,
    rt.code AS reward_type,
    e.amount,
    e.state,
    e.ref_type,
    e.ref_id
   FROM ((finance.ledger_entries e
     JOIN finance.ledger_accounts a ON ((a.id = e.account_id)))
     JOIN market.reward_types rt ON ((rt.id = e.reward_type_id)))
  WHERE ( SELECT ops.has_admin(VARIADIC ARRAY['admin_finance'::text]) AS has_admin);

REVOKE ALL ON FUNCTION "api"."worker_retry_later"(text, bigint, integer, uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."worker_retry_later"(text, bigint, integer, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_retry_later"(text, bigint, integer, uuid) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."worker_retry_later"(text, bigint, integer, uuid) TO "service_role";

GRANT SELECT ON TABLE "api"."admin_ledger" TO "authenticated";
