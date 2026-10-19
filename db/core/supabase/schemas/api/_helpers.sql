-- Helper internal untuk fungsi api core (bukan endpoint; tidak di-grant ke siapa pun): error berkode, sesi, notifikasi org,
-- visibilitas campaign, eligibility claim (CTA F-C03), ringkasan budget & rate. Dipanggil fungsi security definer lain.
--
-- Konvensi error fungsi api core (UI memetakan KODE ke teks; DETAIL = penjelasan bahasa Indonesia untuk log):
--   errcode 42501  auth:no_session            tidak ada JWT identity / iss salah
--                  auth:forbidden             role org / admin (aal2) tidak cukup
--   errcode P0002  not_found:<objek>          campaign | submission | org | reward_type | invite — tidak ada atau tidak terlihat
--   errcode P0001  kode bisnis, mis. invalid:<field>, invalid_state:<status>, campaign_locked, org_not_verified, invoice_unpaid
--   Claim (api.claim_campaign) — urutan cek sama dengan cta_state api.list_campaigns:
--     deadline_passed                      status tracking/settling/settled atau submit_deadline lewat
--     budget_exhausted                     status exhausted atau semua pool habis
--     already_claimed                      masih ada claim terbuka (cta claimed_not_submitted)
--     not_eligible:campaign_not_live       paused/scheduled/draft (terlihat anggota org/admin)
--     slots_full                           kuota clipper (clipper_quota) penuh
--     not_eligible:profile_missing         belum ensure_profile
--     not_eligible:profile_inactive        E-01 suspended/banned/closed
--     not_eligible:own_org                 anggota org pemilik (langsung atau lewat agency)
--     not_eligible:not_invited             campaign invite tanpa undangan
--     not_eligible:min_trust_score         Trust Score < ambang
--     not_eligible:kyc_required            claim JWT kyc ≠ approved
--     not_eligible:need_social_account:<platform>   belum ada akun verified di platform campaign
--     not_eligible:min_followers           follower kurang di semua akun platform campaign
--     not_eligible:min_account_age         umur akun (platform_created_at) kurang
--     not_eligible:max_clips               submisi (selain ditolak) sudah = max_clips_per_clipper

create function market.fail(p_code text, p_detail text default null, p_errcode text default 'P0001') returns void
language plpgsql set search_path = '' as $$
begin
  raise exception using message = p_code, errcode = p_errcode, detail = coalesce(p_detail, '');
end $$;

-- policy:core.iss-identity — uid pemanggil; tanpa sesi identity → 42501.
create function market.session_uid() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null or not ops.iss_ok() then
    perform market.fail('auth:no_session', 'butuh sesi identity', '42501');
  end if;
  return uid;
end $$;

-- Anggota langsung org (bukan lewat agency): dipakai aksi pengelolaan anggota & persetujuan tautan agency.
create function market.is_direct_member(p_org uuid, p_user uuid, variadic p_roles market.org_role[] default '{}') returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  return exists (select 1 from market.org_members m where m.org_id = p_org and m.user_id = p_user
                 and (cardinality(p_roles) = 0 or m.role = any (p_roles)));
end $$;

-- fn:notify_org — notifikasi ke anggota org (langsung + agency tertaut) dengan role tertentu (NULL/kosong = semua).
-- Dipakai invoice.issued, campaign.approved/rejected, managed.draft_ready, org.verified/rejected, budget.*, submission.pending_review.
create function market.notify_org(p_org uuid, p_roles market.org_role[], p_event text, p_payload jsonb default '{}') returns int
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n int := 0;
begin
  for r in
    select m.user_id from market.org_members m
     where m.org_id = p_org and (coalesce(cardinality(p_roles), 0) = 0 or m.role = any (p_roles))
    union
    select m.user_id from market.org_links l join market.org_members m on m.org_id = l.agency_org_id
     where l.client_org_id = p_org and l.approved_at is not null and l.revoked_at is null
       and (coalesce(cardinality(p_roles), 0) = 0 or m.role = any (p_roles))
  loop
    perform ops.enqueue_notification(r.user_id, p_event, coalesce(p_payload, '{}') || jsonb_build_object('org_id', p_org));
    n := n + 1;
  end loop;
  return n;
end $$;

-- Salinan semantik RLS market.campaigns (policy campaigns_public_anon / _public_auth / _org_read / _admin_read) untuk fungsi
-- security definer (definer melewati RLS). Tes core_contracts_market membandingkan hasilnya dengan api.campaigns per user.
create function market.campaign_visible(p market.campaigns) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  pub boolean := p.status in ('live', 'paused', 'tracking', 'exhausted', 'settling', 'settled') and not p.is_template;
begin
  if uid is null then
    return pub and p.visibility = 'public';
  end if;
  if not ops.iss_ok() then
    return false;
  end if;
  return (pub and (p.visibility = 'public'
                   or (p.visibility = 'invite' and market.is_invited(p.id))
                   or (p.visibility = 'level' and exists (select 1 from market.profiles pr
                                                          where pr.id = uid and pr.trust_score >= p.min_trust_score))))
      or ops.is_org_member(p.org_id) or ops.has_admin();
end $$;

-- Rate per 1.000 views sebuah rule (tiered_cpm = tier pertama); NULL untuk rule yang tidak dibayar per views.
create function market.rule_rate(p_kind text, p_params jsonb) returns numeric
language sql immutable set search_path = '' as $$
  select case p_kind when 'per_1k_views' then (p_params ->> 'rate')::numeric
                     when 'tiered_cpm' then (p_params -> 'tiers' -> 0 ->> 'rate')::numeric end;
$$;

-- Angka JSON (number atau string angka) → numeric; selain itu NULL.
create function market.jnum(p jsonb) returns numeric
language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p) = 'number' then (p #>> '{}')::numeric
              when jsonb_typeof(p) = 'string' and (p #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' then (p #>> '{}')::numeric end;
$$;

-- Ringkasan budget & rate satu campaign (card F-C03, detail F-C04, dashboard F-B05): pool + sisa + estimasi sisa views per
-- platform (sisa pool × 1.000 ÷ jumlah rate per views rule aktif di pool itu; per platform diambil pool yang paling lama habis).
create function market.campaign_budget(p_campaign uuid) returns jsonb
language sql stable set search_path = '' as $$
  with rules as (
    select r.id, r.kind, r.platform, r.reward_type_id, r.pool_id, r.params, r.effective_from, rt.code, rt.unit_label, rt.decimals,
           market.rule_rate(r.kind, r.params) as rate
      from market.rate_rules r join market.reward_types rt on rt.id = r.reward_type_id
     where r.campaign_id = p_campaign and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
  ), pools as (
    select pl.id, pl.reward_type_id, pl.total, pl.allocated, pl.total - pl.allocated as remaining, pl.max_per_clip,
           rt.code, rt.unit_label, rt.decimals, rt.idr_value_per_unit
      from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
     where pl.campaign_id = p_campaign
  ), est as (
    select pl.id as pool_id, pf.p as platform, floor(pl.remaining * 1000 / sum(r.rate))::bigint as views
      from pools pl
      cross join unnest((select c.platforms from market.campaigns c where c.id = p_campaign)) pf(p)
      join rules r on r.pool_id = pl.id and r.rate > 0 and (r.platform is null or r.platform = pf.p)
     group by pl.id, pf.p, pl.remaining
  )
  select jsonb_build_object(
    'pools', coalesce((select jsonb_agg(jsonb_build_object(
                'pool_id', pl.id, 'reward_type_id', pl.reward_type_id, 'code', pl.code, 'unit_label', pl.unit_label,
                'decimals', pl.decimals, 'idr_value_per_unit', trim_scale(pl.idr_value_per_unit), 'total', trim_scale(pl.total),
                'allocated', trim_scale(pl.allocated), 'remaining', trim_scale(pl.remaining),
                'max_per_clip', trim_scale(pl.max_per_clip),
                'est_remaining_views', coalesce((select jsonb_object_agg(e.platform, e.views) from est e where e.pool_id = pl.id),
                                                '{}'::jsonb)) order by pl.code, pl.id) from pools pl), '[]'::jsonb),
    'rates', coalesce((select jsonb_agg(jsonb_build_object(
                'rule_id', r.id, 'kind', r.kind, 'platform', r.platform, 'reward_type_id', r.reward_type_id, 'code', r.code,
                'unit_label', r.unit_label, 'decimals', r.decimals, 'pool_id', r.pool_id, 'params', r.params,
                'effective_from', r.effective_from) order by r.platform nulls first, r.code, r.kind, r.id) from rules r), '[]'::jsonb),
    'budget_idr', coalesce((select trim_scale(round(sum(pl.total * pl.idr_value_per_unit), 2)) from pools pl), 0),
    'spent_idr', coalesce((select trim_scale(round(sum(pl.allocated * pl.idr_value_per_unit), 2)) from pools pl), 0),
    'remaining_idr', coalesce((select trim_scale(round(sum(pl.remaining * pl.idr_value_per_unit), 2)) from pools pl), 0),
    'est_remaining_views', coalesce((select jsonb_object_agg(x.platform, x.views)
                                       from (select e.platform, max(e.views) as views from est e group by e.platform) x), '{}'::jsonb));
$$;

-- CTA F-C03 / eligibility claim untuk pemanggil (auth.uid). state ∈ can_claim | claimed_not_submitted | slots_full |
-- budget_exhausted | deadline_passed | not_eligible (+ reason, kode di kepala file). uid NULL (anon) → NULL.
-- Visibilitas dicek pemanggil (market.campaign_visible). claim_campaign memakai fungsi yang sama → CTA = hasil claim.
create function market.claim_check(p_campaign uuid, out state text, out reason text)
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  c market.campaigns;
  pr market.profiles;
  acc record;
begin
  select * into c from market.campaigns where id = p_campaign;
  if uid is null or c.id is null then
    return;
  end if;
  if c.status in ('tracking', 'settling', 'settled') or c.submit_deadline <= now() then
    state := 'deadline_passed';
    return;
  end if;
  if c.status = 'exhausted'
     or not exists (select 1 from finance.reward_pools pl where pl.campaign_id = c.id and pl.allocated < pl.total) then
    state := 'budget_exhausted';
    return;
  end if;
  if exists (select 1 from market.claims cl where cl.campaign_id = c.id and cl.user_id = uid
             and cl.status = 'open' and cl.expires_at > now()) then
    state := 'claimed_not_submitted';
    return;
  end if;
  state := 'not_eligible';
  if c.status <> 'live' then
    reason := 'campaign_not_live';
    return;
  end if;
  -- Kuota = clipper berbeda yang memegang slot (claim terbuka belum lewat atau sudah submit); pemegang slot boleh claim lagi.
  if c.clipper_quota is not null
     and not exists (select 1 from market.claims cl where cl.campaign_id = c.id and cl.user_id = uid
                     and (cl.status = 'submitted' or (cl.status = 'open' and cl.expires_at > now())))
     and (select count(distinct cl.user_id) from market.claims cl where cl.campaign_id = c.id
          and (cl.status = 'submitted' or (cl.status = 'open' and cl.expires_at > now()))) >= c.clipper_quota then
    state := 'slots_full';
    return;
  end if;
  select * into pr from market.profiles where id = uid;
  if pr.id is null then
    reason := 'profile_missing';
  elsif not ((pr.status = 'active' and (pr.suspended_until is null or pr.suspended_until <= now()))
             or (pr.status = 'suspended' and pr.suspended_until <= now())) then
    reason := 'profile_inactive';
  elsif ops.org_role(c.org_id) is not null then
    reason := 'own_org';
  elsif c.visibility = 'invite' and not market.is_invited(c.id) then
    reason := 'not_invited';
  elsif pr.trust_score < c.min_trust_score then
    reason := 'min_trust_score';
  elsif c.kyc_required and coalesce((select auth.jwt() ->> 'kyc'), '') <> 'approved' then
    reason := 'kyc_required';
  end if;
  if reason is not null then
    return;
  end if;
  select count(*) as n_acc,
         count(*) filter (where coalesce(a.followers, 0) >= c.min_followers) as n_fol,
         count(*) filter (where coalesce(a.followers, 0) >= c.min_followers
                          and (c.min_account_age_days = 0
                               or a.platform_created_at <= now() - make_interval(days => c.min_account_age_days))) as n_ok
    into acc
    from tracking.social_accounts a
   where a.user_id = uid and a.status = 'verified' and a.platform = any (c.platforms);
  if acc.n_acc = 0 then
    reason := 'need_social_account:' || c.platforms[1];
  elsif acc.n_fol = 0 then
    reason := 'min_followers';
  elsif acc.n_ok = 0 then
    reason := 'min_account_age';
  elsif (select count(*) from tracking.submissions s where s.campaign_id = c.id and s.user_id = uid
         and s.status not in ('rejected', 'rejected_final')) >= c.max_clips_per_clipper then
    reason := 'max_clips';
  else
    state := 'can_claim';
  end if;
end $$;

-- Normalisasi daftar brief (F-B02): hashtag/mention huruf kecil tanpa #/@, link https (tanpa skema → https://), teks di-trim;
-- kosong & duplikat dibuang. Format salah → invalid:<field>.
create function market.norm_list(p jsonb, p_kind text, p_field text) returns text[]
language plpgsql set search_path = '' as $$
declare
  res text[] := '{}';
  x text;
  v text;
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return res;
  end if;
  if jsonb_typeof(p) <> 'array' then
    perform market.fail('invalid:' || p_field, 'harus array');
  end if;
  for x in select jsonb_array_elements_text(p) loop
    v := btrim(x);
    if p_kind = 'hashtag' then
      v := lower(ltrim(v, '#'));
      if v <> '' and v !~ '^[[:lower:][:digit:]_]+$' then
        perform market.fail('invalid:' || p_field, format('hashtag "%s" hanya boleh huruf, angka, _', x));
      end if;
    elsif p_kind = 'mention' then
      v := lower(ltrim(v, '@'));
      if v <> '' and v !~ '^[[:lower:][:digit:]_.]+$' then
        perform market.fail('invalid:' || p_field, format('mention "%s" hanya boleh huruf, angka, _ dan .', x));
      end if;
    elsif p_kind = 'link' and v <> '' then
      if v !~* '^[a-z][a-z0-9+.-]*://' then
        v := 'https://' || v;
      end if;
      if v !~ '^https://\S+$' then
        perform market.fail('invalid:' || p_field, format('link "%s" wajib https', x));
      end if;
    end if;
    if v <> '' and not (v = any (res)) then
      res := res || v;
    end if;
  end loop;
  return res;
end $$;

-- Validasi parameter rate rule per kind (§10.2), lebih rinci dari constraint rate_rules_params_per_kind.
create function market.check_rule_params(p_kind text, p jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  t jsonb;
  prev numeric := -1;
  i int := 0;
begin
  if jsonb_typeof(p) is distinct from 'object' then
    perform market.fail('invalid:rule_params', 'params harus object');
  end if;
  if p_kind = 'per_1k_views' then
    if coalesce(market.jnum(p -> 'rate'), 0) <= 0 then
      perform market.fail('invalid:rule_params', 'per_1k_views butuh rate > 0');
    end if;
  elsif p_kind = 'flat_per_post' then
    if coalesce(market.jnum(p -> 'amount'), 0) <= 0 then
      perform market.fail('invalid:rule_params', 'flat_per_post butuh amount > 0');
    end if;
  elsif p_kind = 'milestone_bonus' then
    if coalesce(market.jnum(p -> 'threshold'), 0) <= 0 or coalesce(market.jnum(p -> 'amount'), 0) <= 0 then
      perform market.fail('invalid:rule_params', 'milestone_bonus butuh threshold & amount > 0');
    end if;
  elsif p_kind = 'tiered_cpm' then
    if jsonb_typeof(p -> 'tiers') is distinct from 'array' or jsonb_array_length(p -> 'tiers') = 0 then
      perform market.fail('invalid:rule_params', 'tiered_cpm butuh tiers [{from, to, rate}]');
    end if;
    for t in select jsonb_array_elements(p -> 'tiers') loop
      if market.jnum(t -> 'from') is null or market.jnum(t -> 'from') <= prev or coalesce(market.jnum(t -> 'rate'), 0) <= 0
         or (i = 0 and market.jnum(t -> 'from') <> 0)
         or (t ? 'to' and jsonb_typeof(t -> 'to') <> 'null' and market.jnum(t -> 'to') <= market.jnum(t -> 'from')) then
        perform market.fail('invalid:rule_params', 'tier harus mulai dari 0, naik, rate > 0');
      end if;
      prev := market.jnum(t -> 'from');
      i := i + 1;
    end loop;
  else
    perform market.fail('invalid:rule_kind', coalesce(p_kind, 'null'));
  end if;
end $$;

revoke execute on function market.fail(text, text, text), market.session_uid(), market.is_direct_member(uuid, uuid, market.org_role[]),
  market.notify_org(uuid, market.org_role[], text, jsonb), market.campaign_visible(market.campaigns), market.rule_rate(text, jsonb),
  market.jnum(jsonb), market.campaign_budget(uuid), market.claim_check(uuid), market.norm_list(jsonb, text, text),
  market.check_rule_params(text, jsonb) from public;
