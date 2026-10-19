-- Campaign: daftar marketplace + claim (clipper), builder & kontrol (brand/admin). Konvensi errcode: kepala api/_helpers.sql.
--
-- Kode error api.claim_campaign (errcode P0001; P0002 untuk not_found) — urutan cek = urutan cta_state api.list_campaigns,
-- jadi tombol di card selalu sama dengan hasil claim (satu fungsi: market.claim_check):
--   not_found:campaign                         tidak ada / tidak terlihat (draft, template, invite tanpa undangan, level kurang)
--   deadline_passed                            status tracking/settling/settled atau submit_deadline lewat    cta deadline_passed
--   budget_exhausted                           status exhausted atau semua pool habis                         cta budget_exhausted
--   already_claimed                            masih ada claim terbuka                                        cta claimed_not_submitted
--   not_eligible:campaign_not_live             paused / scheduled (terlihat anggota org & admin)              cta not_eligible
--   slots_full                                 kuota clipper (clipper_quota) penuh                            cta slots_full
--   not_eligible:profile_missing               belum ensure_profile
--   not_eligible:profile_inactive              E-01 suspended / banned / closed
--   not_eligible:own_org                       anggota org pemilik (langsung atau lewat agency)
--   not_eligible:not_invited                   campaign invite tanpa undangan (hanya terlihat admin)
--   not_eligible:min_trust_score               Trust Score < min_trust_score
--   not_eligible:kyc_required                  claim JWT kyc ≠ approved
--   not_eligible:need_social_account:<platform> belum ada akun verified di platform campaign (platform pertama disebut)
--   not_eligible:min_followers                 follower semua akun platform campaign < min_followers
--   not_eligible:min_account_age               umur akun (platform_created_at) < min_account_age_days
--   not_eligible:max_clips                     submisi (selain ditolak) sudah = max_clips_per_clipper

-- F-C03 daftar campaign untuk anon (landing, cta NULL) dan clipper login (cta_state + alasan per user).
-- p_filters: {q, platform, category, status (string | array | "all"; default live+paused), sort: newest|rate|budget|deadline,
-- limit ≤ 50}. Pinned dulu (pinned_until > now(), urut pinned_rank), lalu urutan sort. Keyset: kirim next_cursor baris terakhir.
-- Security definer (butuh hitung kuota lintas user); visibilitas = market.campaign_visible (salinan RLS campaigns).
create function api.list_campaigns(p_filters jsonb default '{}', p_cursor text default null)
returns table (id uuid, slug text, title text, type text, category_id text, status market.campaign_status,
               platforms market.platform[], visibility text, start_at timestamptz, submit_deadline timestamptz, cover_path text,
               is_pinned boolean, pinned_rank smallint, is_new boolean, rates jsonb, budget_idr numeric, remaining_idr numeric,
               est_remaining_views jsonb, cta_state text, cta_reason text, brand_name text, brand_verified boolean,
               next_cursor text)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid uuid := (select auth.uid());
  f jsonb := coalesce(p_filters, '{}');
  v_sort text := coalesce(f ->> 'sort', 'newest');
  v_limit int := least(greatest(coalesce(market.jnum(f -> 'limit')::int, 20), 1), 50);
  v_q text := nullif(lower(btrim(f ->> 'q')), '');
  v_platform market.platform := nullif(f ->> 'platform', '')::market.platform;
  v_category text := nullif(f ->> 'category', '');
  v_slug text := nullif(f ->> 'slug', '');  -- halaman publik {domain}/c/[slug]
  pub constant market.campaign_status[] := array['live', 'paused', 'tracking', 'exhausted', 'settling', 'settled']::market.campaign_status[];
  v_status market.campaign_status[] := array['live', 'paused']::market.campaign_status[];
  new_days int := coalesce((select (s.value #>> '{}')::int from ops.settings s where s.key = 'public.market.new_badge_days'), 3);
  cur text[];
  cg int;
  cr int;
  ck numeric;
  cid uuid;
begin
  if uid is not null and not ops.iss_ok() then
    perform market.fail('auth:no_session', 'butuh sesi identity', '42501');
  end if;
  if v_sort not in ('newest', 'rate', 'budget', 'deadline') then
    perform market.fail('invalid:sort', v_sort);
  end if;
  if jsonb_typeof(f -> 'status') = 'array' then
    v_status := array(select jsonb_array_elements_text(f -> 'status'))::market.campaign_status[];
  elsif f ->> 'status' = 'all' then
    v_status := pub;
  elsif nullif(f ->> 'status', '') is not null then
    v_status := array[(f ->> 'status')::market.campaign_status];
  end if;
  if p_cursor is not null then
    cur := string_to_array(p_cursor, '|');
    begin
      cg := cur[1]::int; cr := cur[2]::int; ck := cur[3]::numeric; cid := cur[4]::uuid;
    exception when others then
      perform market.fail('invalid:cursor', p_cursor);
    end;
    if cardinality(cur) <> 4 or cid is null then
      perform market.fail('invalid:cursor', p_cursor);
    end if;
  end if;

  return query
  with base as (
    select c.id, c.org_id, c.slug, c.title, c.type, c.category_id, c.status, c.platforms, c.visibility, c.start_at, c.submit_deadline,
           c.created_at, c.pinned_rank, coalesce(c.pinned_until > now(), false) as pinned,
           (select coalesce(sum((pl.total - pl.allocated) * rt.idr_value_per_unit), 0)
              from finance.reward_pools pl join market.reward_types rt on rt.id = pl.reward_type_id
             where pl.campaign_id = c.id) as rem_idr,
           (select max(x.s) from (select sum(market.rule_rate(r.kind, r.params) * rt.idr_value_per_unit) as s
                                    from unnest(c.platforms) pf(p)
                                    join market.rate_rules r on r.campaign_id = c.id and (r.platform is null or r.platform = pf.p)
                                     and r.effective_from <= now() and (r.effective_to is null or r.effective_to > now())
                                    join market.reward_types rt on rt.id = r.reward_type_id
                                   group by pf.p) x) as rate_idr
      from market.campaigns c
     where c.status = any (v_status) and c.status = any (pub) and not c.is_template
       and (c.visibility = 'public' or market.campaign_visible(c))
       and (v_platform is null or v_platform = any (c.platforms))
       and (v_category is null or c.category_id = v_category)
       and (v_slug is null or c.slug = v_slug)
       and (v_q is null or position(v_q in lower(c.title)) > 0 or ltrim(v_q, '#') = any (c.required_hashtags))
  ), keyed as (
    select b.*, case when b.pinned then 0 else 1 end as g,
           case when b.pinned then coalesce(b.pinned_rank, 32767) else 32767 end::int as r,
           case v_sort when 'newest' then -extract(epoch from coalesce(b.start_at, b.created_at))
                       when 'rate' then -coalesce(b.rate_idr, 0)
                       when 'budget' then -b.rem_idr
                       else coalesce(extract(epoch from b.submit_deadline), 1e12) end as k
      from base b
  ), page as (
    select kk.* from keyed kk
     where p_cursor is null or (kk.g, kk.r, kk.k, kk.id) > (cg, cr, ck, cid)
     order by kk.g, kk.r, kk.k, kk.id
     limit v_limit
  )
  select pg.id, pg.slug, pg.title, pg.type, pg.category_id, pg.status, pg.platforms, pg.visibility, pg.start_at, pg.submit_deadline,
         (select a.storage_path from market.campaign_assets a where a.campaign_id = pg.id and a.kind = 'cover'
           order by a.created_at limit 1),
         pg.pinned, case when pg.pinned then pg.pinned_rank end, coalesce(pg.start_at, pg.created_at) > now() - make_interval(days => new_days),
         bb.bud -> 'rates', (bb.bud ->> 'budget_idr')::numeric, trim_scale(round(pg.rem_idr, 2)), bb.bud -> 'est_remaining_views',
         cc.state, cc.reason, o.name, o.status = 'verified', concat_ws('|', pg.g, pg.r, pg.k, pg.id)
    from page pg
    join market.organizations o on o.id = pg.org_id
    cross join lateral (select market.campaign_budget(pg.id) as bud) bb
    cross join lateral market.claim_check(pg.id) cc
   order by pg.g, pg.r, pg.k, pg.id;
end $$;

-- F-C05: claim = reservasi 1 slot submit, kedaluwarsa public.market.claim_hours (48). Cek sama dengan CTA (market.claim_check);
-- advisory lock per campaign supaya kuota tidak terlewati claim bersamaan. Claim terbuka yang sudah lewat waktu → expired dulu.
create function api.claim_campaign(p_campaign uuid) returns market.claims
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  chk record;
  cl market.claims;
  hours int := coalesce((select (s.value #>> '{}')::int from ops.settings s where s.key = 'public.market.claim_hours'), 48);
begin
  perform pg_advisory_xact_lock(hashtextextended('claim:' || p_campaign::text, 0));
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null or not market.campaign_visible(c) then
    perform market.fail('not_found:campaign', 'campaign tidak ada atau tidak terlihat', 'P0002');
  end if;
  update market.claims set status = 'expired'
   where campaign_id = c.id and user_id = uid and status = 'open' and expires_at <= now();
  select * into chk from market.claim_check(c.id);
  if chk.state is distinct from 'can_claim' then
    perform market.fail(case chk.state when 'claimed_not_submitted' then 'already_claimed'
                                       when 'not_eligible' then 'not_eligible:' || chk.reason
                                       else chk.state end,
                        'claim ditolak');
  end if;
  begin
    insert into market.claims (campaign_id, user_id, expires_at)
    values (c.id, uid, now() + make_interval(hours => hours))
    returning * into cl;
  exception when unique_violation then
    perform market.fail('already_claimed', 'masih ada claim terbuka di campaign ini');
  end;
  return cl;
end $$;

-- F-B02/F-A03 builder. p_campaign: {id?, org_id (wajib saat buat), kolom campaign..., pools: [{key|id, reward_type_id, total,
-- max_per_clip}], rules: [{kind, platform?, pool (key|id) | reward_type_id, params}], assets: [{kind, storage_path | url,
-- size_bytes?, audience?}] (daftar lengkap: yang tidak ada dihapus), fee_rule (admin saja: {mgmt_fee_pct, ...} | null)}.
-- pools/rules/assets diganti hanya kalau key-nya ada. Status rejected → kembali draft saat disimpan. Sejak in_review hanya faq.
-- p_submit: brand (atau admin untuk campaign self_serve) → in_review + invoice campaign; admin pada draft managed → kirim ke
-- brand (invoice managed_service + managed.draft_ready, tetap draft).
create function api.save_campaign(p_campaign jsonb, p_submit boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  p jsonb := coalesce(p_campaign, '{}');
  is_admin boolean := ops.has_admin('admin_ops');
  is_brand boolean;
  cols constant text[] := array['title', 'slug', 'type', 'category_id', 'platforms', 'brief', 'managed_brief', 'required_hashtags',
    'required_mentions', 'required_links', 'sponsored_label', 'min_duration_sec', 'max_duration_sec', 'dos', 'donts', 'example_urls',
    'faq', 'service_mode', 'start_at', 'submit_deadline', 'view_window_days', 'review_mode', 'min_followers', 'min_account_age_days',
    'min_trust_score', 'kyc_required', 'min_views', 'max_clips_per_clipper', 'clipper_quota', 'allow_video_reuse', 'visibility',
    'is_template'];
  c market.campaigns;
  org market.organizations;
  patch jsonb := '{}';
  k text;
  present text[];
  e jsonb;
  pid uuid;
  rt market.reward_types;
  kept uuid[] := '{}';
  kept_assets uuid[] := '{}';
  pool_map jsonb := '{}';
  plat market.platform;
  prefix text;
  aid uuid;
  a_path text;
  a_url text;
  paid_sub numeric;
  send_to_brand boolean;
  inv finance.invoices;
begin
  if jsonb_typeof(p) <> 'object' then
    perform market.fail('invalid:payload', 'p_campaign harus object');
  end if;
  for k in select jsonb_object_keys(p) loop
    if not (k = any (cols) or k in ('id', 'org_id', 'pools', 'rules', 'assets', 'fee_rule')) then
      perform market.fail('invalid:unknown_key', k);
    end if;
  end loop;
  if p ? 'id' then
    select * into c from market.campaigns where id = (p ->> 'id')::uuid for update;
    if c.id is null then
      perform market.fail('not_found:campaign', null, 'P0002');
    end if;
    if p ? 'org_id' and (p ->> 'org_id')::uuid is distinct from c.org_id then
      perform market.fail('invalid:org_id', 'campaign tidak bisa pindah org');
    end if;
  end if;
  select * into org from market.organizations where id = coalesce(c.org_id, (p ->> 'org_id')::uuid);
  if org.id is null then
    perform market.fail('not_found:org', null, 'P0002');
  end if;
  is_brand := ops.is_org_member(org.id, 'brand_owner', 'brand_manager');
  if not (is_brand or is_admin) or (p ? 'fee_rule' and not is_admin) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org atau admin_ops aal2', '42501');
  end if;
  if org.status = 'suspended' then
    perform market.fail('org_suspended', 'org disuspend');
  end if;

  -- Sejak diajukan brief terkunci (trigger campaigns_brief_frozen); di sini hanya FAQ yang diterima.
  if c.id is not null and c.status not in ('draft', 'rejected') then
    if p_submit or exists (select 1 from jsonb_object_keys(p) x where x not in ('id', 'org_id', 'faq')) then
      perform market.fail('campaign_locked', format('campaign %s: yang bisa diubah hanya faq', c.status));
    end if;
    if p ? 'faq' then
      update market.campaigns set faq = p -> 'faq' where id = c.id;
    end if;
    return c.id;
  end if;

  -- Kolom campaign (dinormalisasi)
  for k in select x from jsonb_object_keys(p) x where x = any (cols) loop
    patch := patch || jsonb_build_object(k, p -> k);
  end loop;
  if patch ? 'title' then
    patch := patch || jsonb_build_object('title', btrim(patch ->> 'title'));
  end if;
  if patch ? 'required_hashtags' then
    patch := patch || jsonb_build_object('required_hashtags', market.norm_list(p -> 'required_hashtags', 'hashtag', 'required_hashtags'));
  end if;
  if patch ? 'required_mentions' then
    patch := patch || jsonb_build_object('required_mentions', market.norm_list(p -> 'required_mentions', 'mention', 'required_mentions'));
  end if;
  if patch ? 'required_links' then
    patch := patch || jsonb_build_object('required_links', market.norm_list(p -> 'required_links', 'link', 'required_links'));
  end if;
  if patch ? 'example_urls' then
    patch := patch || jsonb_build_object('example_urls', market.norm_list(p -> 'example_urls', 'link', 'example_urls'));
  end if;
  if patch ? 'dos' then
    patch := patch || jsonb_build_object('dos', market.norm_list(p -> 'dos', 'text', 'dos'));
  end if;
  if patch ? 'donts' then
    patch := patch || jsonb_build_object('donts', market.norm_list(p -> 'donts', 'text', 'donts'));
  end if;
  if patch ? 'slug' then
    patch := patch || jsonb_build_object('slug', lower(btrim(patch ->> 'slug')));
    if (patch ->> 'slug') !~ '^[a-z0-9-]{3,80}$' then
      perform market.fail('invalid:slug', 'slug 3–80 huruf kecil, angka, -');
    end if;
  elsif c.id is null then
    patch := patch || jsonb_build_object('slug',
      left(coalesce(nullif(btrim(regexp_replace(lower(coalesce(patch ->> 'title', '')), '[^a-z0-9]+', '-', 'g'), '-'), ''), 'campaign'), 60)
      || '-' || substr(md5(gen_random_uuid()::text), 1, 6));
  end if;
  if exists (select 1 from market.campaigns x where x.slug = patch ->> 'slug' and x.id is distinct from c.id) then
    perform market.fail('slug_taken', patch ->> 'slug');
  end if;

  select array_agg(x) into present from jsonb_object_keys(patch) x;
  if c.id is null then
    patch := patch || jsonb_build_object('org_id', org.id, 'created_by', uid);
    present := present || array['org_id', 'created_by'];
    execute format('insert into market.campaigns (%1$s) select %1$s from jsonb_populate_record(null::market.campaigns, $1) returning *',
                   (select string_agg(quote_ident(x), ', ') from unnest(present) x))
      using patch into c;
  else
    if c.status = 'rejected' then
      update market.campaigns set status = 'draft' where id = c.id;
    end if;
    if cardinality(present) > 0 then
      execute format('update market.campaigns t set (%1$s) = (select %1$s from jsonb_populate_record(null::market.campaigns, $1)) '
                     'where t.id = $2', (select string_agg(quote_ident(x), ', ') from unnest(present) x))
        using patch, c.id;
    end if;
    select * into c from market.campaigns where id = c.id;
  end if;

  -- Pool & rate rule (§10). rules diganti → hapus dulu supaya pool bisa diganti.
  if p ? 'rules' then
    delete from market.rate_rules where campaign_id = c.id;
  end if;
  if p ? 'pools' then
    if jsonb_typeof(p -> 'pools') <> 'array' then
      perform market.fail('invalid:pools', 'pools harus array');
    end if;
    for e in select jsonb_array_elements(p -> 'pools') loop
      select * into rt from market.reward_types where id = (e ->> 'reward_type_id')::uuid
         and (owner_org_id is null or owner_org_id = org.id);
      if rt.id is null then
        perform market.fail('invalid:reward_type', e ->> 'reward_type_id');
      end if;
      if coalesce(market.jnum(e -> 'total'), 0) <= 0 or coalesce(market.jnum(e -> 'max_per_clip'), 0) <= 0 then
        perform market.fail('invalid:pool', 'total & max_per_clip wajib > 0');
      end if;
      pid := null;
      if e ? 'id' then
        update finance.reward_pools set reward_type_id = rt.id, total = market.jnum(e -> 'total'),
               max_per_clip = market.jnum(e -> 'max_per_clip')
         where id = (e ->> 'id')::uuid and campaign_id = c.id
        returning id into pid;
        if pid is null then
          perform market.fail('invalid:pool_id', e ->> 'id');
        end if;
      else
        insert into finance.reward_pools (campaign_id, reward_type_id, total, max_per_clip)
        values (c.id, rt.id, market.jnum(e -> 'total'), market.jnum(e -> 'max_per_clip'))
        returning id into pid;
      end if;
      kept := kept || pid;
      if e ? 'key' then
        pool_map := pool_map || jsonb_build_object(e ->> 'key', pid);
      end if;
    end loop;
    begin
      delete from finance.reward_pools where campaign_id = c.id and not (id = any (kept));
    exception when foreign_key_violation then
      perform market.fail('invalid:pool_in_use', 'pool masih dipakai rate rule; kirim rules juga');
    end;
  end if;
  select pool_map || coalesce(jsonb_object_agg(pl.id::text, pl.id), '{}') into pool_map
    from finance.reward_pools pl where pl.campaign_id = c.id;
  if p ? 'rules' then
    if jsonb_typeof(p -> 'rules') <> 'array' then
      perform market.fail('invalid:rules', 'rules harus array');
    end if;
    for e in select jsonb_array_elements(p -> 'rules') loop
      perform market.check_rule_params(e ->> 'kind', e -> 'params');
      plat := nullif(e ->> 'platform', '')::market.platform;
      if plat is not null and not (plat = any (c.platforms)) then
        perform market.fail('invalid:rule_platform', plat::text);
      end if;
      pid := coalesce((pool_map ->> (e ->> 'pool'))::uuid, (pool_map ->> (e ->> 'pool_id'))::uuid);
      if pid is null and e ? 'reward_type_id' then
        select min(pl.id::text)::uuid into pid from finance.reward_pools pl
         where pl.campaign_id = c.id and pl.reward_type_id = (e ->> 'reward_type_id')::uuid
        having count(*) = 1;
      end if;
      if pid is null then
        perform market.fail('invalid:rule_pool', 'rule harus menunjuk satu pool campaign ini');
      end if;
      if e ? 'reward_type_id' and not exists (select 1 from finance.reward_pools pl where pl.id = pid
                                              and pl.reward_type_id = (e ->> 'reward_type_id')::uuid) then
        perform market.fail('invalid:rule_reward_type', 'reward type rule ≠ reward type pool');
      end if;
      insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, platform, params)
      select c.id, e ->> 'kind', pl.reward_type_id, pl.id, plat, e -> 'params' from finance.reward_pools pl where pl.id = pid;
    end loop;
  end if;

  -- Aset (E-10): file wajib di folder {org}/{campaign}/ (internal/ = berkas brief mentah, hanya anggota org + admin).
  if p ? 'assets' then
    if jsonb_typeof(p -> 'assets') <> 'array' then
      perform market.fail('invalid:assets', 'assets harus array');
    end if;
    prefix := org.id::text || '/' || c.id::text || '/';
    for e in select jsonb_array_elements(p -> 'assets') loop
      a_path := nullif(btrim(e ->> 'storage_path'), '');
      a_url := (market.norm_list(case when e ? 'url' then jsonb_build_array(e -> 'url') end, 'link', 'asset_url'))[1];
      if a_path is not null and left(a_path, length(prefix)) <> prefix then
        perform market.fail('invalid:asset_path', format('file harus di folder %s', prefix));
      end if;
      select x.id into aid from market.campaign_assets x
       where x.campaign_id = c.id and (x.storage_path = a_path or x.url = a_url) limit 1;
      if aid is null then
        insert into market.campaign_assets (campaign_id, kind, storage_path, url, size_bytes, audience)
        values (c.id, e ->> 'kind', a_path, a_url, market.jnum(e -> 'size_bytes')::bigint,
                coalesce(e ->> 'audience', case when split_part(a_path, '/', 3) = 'internal' then 'internal' else 'clipper' end))
        returning id into aid;
      end if;
      kept_assets := kept_assets || aid;
    end loop;
    delete from market.campaign_assets where campaign_id = c.id and not (id = any (kept_assets));
  end if;

  -- Override fee per campaign (F-A03, admin).
  if p ? 'fee_rule' then
    update market.campaigns set fee_rule_id = case when jsonb_typeof(p -> 'fee_rule') = 'null' then null
      else finance.create_fee_rule('campaign', p -> 'fee_rule', finance.effective_fee_rule(org.id, null), uid) end
     where id = c.id;
  end if;

  -- Invoice campaign yang sudah lunas mengunci budget (pool bisa ditambah lewat top-up saja).
  select sum(i.subtotal) into paid_sub from finance.invoices i
   where i.campaign_id = c.id and i.kind in ('campaign', 'topup') and i.status = 'paid';
  if paid_sub is not null and p ? 'pools' and round(finance.campaign_budget_idr(c.id), 2) <> paid_sub then
    perform market.fail('pools_locked_after_payment', 'budget sudah dibayar; ubah lewat top-up');
  end if;

  if not p_submit then
    return c.id;
  end if;

  select * into c from market.campaigns where id = c.id;
  if c.is_template then
    perform market.fail('invalid:template', 'template tidak bisa diajukan; duplikat dulu');
  end if;
  if c.start_at is null or c.submit_deadline is null then
    perform market.fail('invalid:schedule', 'start_at & submit_deadline wajib');
  end if;
  if c.submit_deadline <= now() then
    perform market.fail('invalid:submit_deadline', 'deadline submit sudah lewat');
  end if;
  if not exists (select 1 from finance.reward_pools pl where pl.campaign_id = c.id) then
    perform market.fail('invalid:pools', 'minimal satu pool');
  end if;
  if exists (select 1 from finance.reward_pools pl where pl.campaign_id = c.id
             and not exists (select 1 from market.rate_rules r where r.pool_id = pl.id)) then
    perform market.fail('invalid:rules', 'tiap pool butuh minimal satu rate rule');
  end if;

  send_to_brand := is_admin and not is_brand and c.service_mode = 'managed';
  if send_to_brand then
    -- J-A7: tim selesai menyusun → invoice paket managed (sekali) + kabari brand; brand yang mengajukan.
    if not exists (select 1 from finance.invoices i where i.campaign_id = c.id and i.kind = 'managed_service' and i.status <> 'void') then
      perform finance.issue_invoice(org.id, c.id, 'managed_service', 0,
        coalesce((select (s.value #>> '{}')::numeric from ops.settings s where s.key = 'public.billing.managed_service_idr'), 2500000));
    end if;
    perform market.notify_org(org.id, array['brand_owner', 'brand_manager']::market.org_role[], 'managed.draft_ready',
                              jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title));
    return c.id;
  end if;

  if org.status <> 'verified' then
    perform market.fail('org_not_verified', 'org belum diverifikasi admin');
  end if;
  -- Brand mengajukan sendiri draft managed (tanpa menunggu tim) → jasa managed tetap ditagih, sekali.
  if c.service_mode = 'managed' and not exists (select 1 from finance.invoices i where i.campaign_id = c.id
                                                and i.kind = 'managed_service' and i.status <> 'void') then
    perform finance.issue_invoice(org.id, c.id, 'managed_service', 0,
      coalesce((select (s.value #>> '{}')::numeric from ops.settings s where s.key = 'public.billing.managed_service_idr'), 2500000));
  end if;
  update market.campaigns set status = 'in_review' where id = c.id;
  if paid_sub is null then
    update finance.invoices set status = 'void' where campaign_id = c.id and kind = 'campaign' and status = 'issued';
    inv := finance.issue_invoice(org.id, c.id, 'campaign', finance.campaign_budget_idr(c.id));
  end if;
  return c.id;
end $$;

-- F-B06 kontrol campaign berjalan (S-01). topup hanya menerbitkan invoice (pool bertambah saat lunas lewat pool_topups).
-- p_params: extend {submit_deadline}; raise_rate {rule_id, params}; topup {pools: [{pool_id, amount}]}.
create function api.control_campaign(p_campaign uuid, p_action text, p_params jsonb default '{}') returns void
language plpgsql security definer set search_path = '' as $$
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
                                     or market.jnum(newp -> 'tiers' -> i -> 'from') <> market.jnum(r.params -> 'tiers' -> i -> 'from'))
           end) then
      perform market.fail('invalid:rate_not_higher', 'rate baru harus lebih tinggi dari rate lama');
    end if;
    -- Rule lama ditutup, rule baru berlaku untuk views sesudahnya (§10.5).
    update market.rate_rules set effective_to = t where id = r.id;
    insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, platform, params, effective_from)
    values (c.id, r.kind, r.reward_type_id, r.pool_id, r.platform, newp, t);
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
end $$;

-- F-B10: salinan selalu draft (tanpa jadwal, pin, aset); pool & rule aktif ikut disalin dengan allocated 0.
create function api.duplicate_campaign(p_campaign uuid, p_as_template boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  nid uuid := gen_random_uuid();
  pl record;
  npid uuid;
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  insert into market.campaigns (id, org_id, slug, title, type, category_id, platforms, brief, required_hashtags, required_mentions,
                                required_links, sponsored_label, min_duration_sec, max_duration_sec, dos, donts, example_urls, faq,
                                view_window_days, review_mode, min_followers, min_account_age_days, min_trust_score, kyc_required,
                                min_views, max_clips_per_clipper, clipper_quota, allow_video_reuse, visibility, is_template,
                                fee_rule_id, created_by)
  values (nid, c.org_id, left(regexp_replace(c.slug, '-[0-9a-f]{6}$', ''), 72) || '-' || substr(md5(nid::text), 1, 6),
          c.title, c.type, c.category_id, c.platforms, c.brief, c.required_hashtags, c.required_mentions, c.required_links,
          c.sponsored_label, c.min_duration_sec, c.max_duration_sec, c.dos, c.donts, c.example_urls, c.faq, c.view_window_days,
          c.review_mode, c.min_followers, c.min_account_age_days, c.min_trust_score, c.kyc_required, c.min_views,
          c.max_clips_per_clipper, c.clipper_quota, c.allow_video_reuse, c.visibility, coalesce(p_as_template, false),
          c.fee_rule_id, uid);
  for pl in select * from finance.reward_pools x where x.campaign_id = c.id order by x.id loop
    insert into finance.reward_pools (campaign_id, reward_type_id, total, max_per_clip)
    values (nid, pl.reward_type_id, pl.total, pl.max_per_clip)
    returning id into npid;
    insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, platform, params)
    select nid, r.kind, r.reward_type_id, npid, r.platform, r.params from market.rate_rules r
     where r.pool_id = pl.id and r.effective_to is null;
  end loop;
  return nid;
end $$;

-- F-B11: undang clipper (username) ke campaign; campaign visibility invite hanya terlihat yang diundang (RLS).
-- Mengembalikan jumlah undangan baru; tiap undangan baru → notifikasi campaign.invited.
create function api.invite_to_campaign(p_campaign uuid, p_usernames text[]) returns int
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  pr record;
  n int := 0;
  k int;
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  if c.is_template or c.status in ('cancelled', 'rejected', 'settling', 'settled') then
    perform market.fail('invalid_state:' || c.status, 'campaign ini tidak bisa menerima undangan');
  end if;
  if coalesce(cardinality(p_usernames), 0) > 500 then
    perform market.fail('invalid:usernames', 'maks 500 username per panggilan');
  end if;
  for pr in select p.id from market.profiles p
             where p.status = 'active'
               and p.username in (select lower(btrim(ltrim(btrim(u), '@'))) from unnest(p_usernames) u) loop
    insert into market.campaign_invites (campaign_id, user_id, invited_by) values (c.id, pr.id, uid) on conflict do nothing;
    get diagnostics k = row_count;
    if k > 0 then
      n := n + 1;
      perform ops.enqueue_notification(pr.id, 'campaign.invited',
                                       jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'campaign_slug', c.slug,
                                                          'org_id', c.org_id,
                                                          'org_name', (select o.name from market.organizations o where o.id = c.org_id)));
    end if;
  end loop;
  return n;
end $$;

-- REV-4 pin berbayar: invoice pinned (harga public.billing.pin_price_per_week_idr per minggu yang dimulai); pin_until diteruskan
-- dari pin yang masih berjalan. pinned_until di campaign diset confirm_invoice_payment saat lunas.
create function api.buy_pin(p_campaign uuid, p_days int) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  price numeric := coalesce((select (s.value #>> '{}')::numeric from ops.settings s where s.key = 'public.billing.pin_price_per_week_idr'),
                            500000);
  inv finance.invoices;
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager', 'brand_finance') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager/brand_finance org', '42501');
  end if;
  if c.status not in ('scheduled', 'live', 'paused') then
    perform market.fail('invalid_state:' || c.status, 'pin hanya untuk campaign terjadwal/berjalan');
  end if;
  if p_days is null or p_days not between 1 and 90 then
    perform market.fail('invalid:days', 'durasi pin 1–90 hari');
  end if;
  inv := finance.issue_invoice(c.org_id, c.id, 'pinned', 0, ceil(p_days / 7.0) * price,
                               greatest(now(), coalesce(c.pinned_until, now())) + make_interval(days => p_days));
  return inv.id;
end $$;

revoke execute on function api.list_campaigns(jsonb, text), api.claim_campaign(uuid), api.save_campaign(jsonb, boolean),
  api.control_campaign(uuid, text, jsonb), api.duplicate_campaign(uuid, boolean), api.invite_to_campaign(uuid, text[]),
  api.buy_pin(uuid, int) from public;
grant execute on function api.list_campaigns(jsonb, text) to anon, authenticated;
grant execute on function api.claim_campaign(uuid), api.save_campaign(jsonb, boolean), api.control_campaign(uuid, text, jsonb),
  api.duplicate_campaign(uuid, boolean), api.invite_to_campaign(uuid, text[]), api.buy_pin(uuid, int) to authenticated;
