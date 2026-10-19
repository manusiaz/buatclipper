SET local check_function_bodies = off;

ALTER TABLE "market"."rate_rules"
  ADD COLUMN "lineage_id" uuid;

CREATE OR REPLACE FUNCTION api.bridge_attach_fulfillment_export (
  p_reward_type uuid,
  p_file_ref    text,
  p_exported    uuid[]
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if p_file_ref is null or btrim(p_file_ref) = '' then
    raise exception 'invalid:file_ref' using errcode = 'P0001';
  end if;
  perform 1 from finance.fulfillments f where f.id = any (coalesce(p_exported, '{}')) order by f.id for update;
  if exists (select 1 from unnest(coalesce(p_exported, '{}')) e(id)
              where not exists (select 1 from finance.fulfillments f join market.reward_types rt on rt.id = f.reward_type_id
                                 where f.id = e.id and f.reward_type_id = p_reward_type and rt.fulfillment = 'manual_export'
                                   and (f.status = 'requested' or f.export_ref = p_file_ref))) then
    raise exception 'export_stale' using errcode = 'P0001', detail = 'klaim berubah sejak dibaca; ekspor ulang';
  end if;
  update finance.fulfillments set status = 'processing', export_ref = p_file_ref where id = any (p_exported) and status = 'requested';
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_fulfillment_export_accepted (
  p_reward_type uuid,
  p_file_ref    text
)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select exists (select 1 from finance.fulfillments f where f.reward_type_id = p_reward_type and f.export_ref = p_file_ref);
$function$;

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
                                     or market.jnum(newp -> 'tiers' -> i -> 'from') <> market.jnum(r.params -> 'tiers' -> i -> 'from'))
           end) then
      perform market.fail('invalid:rate_not_higher', 'rate baru harus lebih tinggi dari rate lama');
    end if;
    -- Rule lama ditutup, rule baru berlaku untuk views sesudahnya (§10.5).
    update market.rate_rules set effective_to = t where id = r.id;
    insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, platform, params, effective_from, lineage_id)
    values (c.id, r.kind, r.reward_type_id, r.pool_id, r.platform, newp, t, coalesce(r.lineage_id, r.id));
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

CREATE OR REPLACE FUNCTION api.save_campaign (
  p_campaign jsonb,
  p_submit   boolean DEFAULT false
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
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
  pools_before jsonb;
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
  if is_admin then  -- F-A11: builder admin (paket managed) tercatat; gagal di bawah = ikut di-rollback
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'campaign.save', 'campaign:' || coalesce(p ->> 'id', 'new'), jsonb_build_object('status', c.status),
            jsonb_build_object('submit', p_submit, 'keys', (select jsonb_agg(k2 order by k2) from jsonb_object_keys(p) k2)));
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
    select jsonb_agg(jsonb_build_array(x.id, x.reward_type_id, x.total) order by x.id) into pools_before
      from finance.reward_pools x where x.campaign_id = c.id;
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

  -- Invoice campaign yang sudah lunas mengunci pool (id, reward type, total = akun ledger campaign_pool yang sudah terisi);
  -- pool bisa ditambah lewat top-up saja.
  select sum(i.subtotal) into paid_sub from finance.invoices i
   where i.campaign_id = c.id and i.kind in ('campaign', 'topup') and i.status = 'paid';
  if paid_sub is not null and p ? 'pools'
     and pools_before is distinct from (select jsonb_agg(jsonb_build_array(x.id, x.reward_type_id, x.total) order by x.id)
                                          from finance.reward_pools x where x.campaign_id = c.id) then
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
end $function$;

CREATE OR REPLACE FUNCTION finance.accrue_earnings (
  p_submission uuid,
  p_snapshot   bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  s tracking.submissions;
  snap tracking.view_snapshots;
  c market.campaigns;
  r market.rate_rules;
  p finance.reward_pools;
  ce finance.clip_earnings;
  pct numeric := (ops.cfg('finance.settlement_threshold_pct', '5'))::numeric;
  entries jsonb := '[]';
  v bigint;
  base bigint;
  crossed boolean;
  view_based boolean;
  raw numeric;
  amt numeric;
  remaining numeric;
  in_settle boolean;
begin
  select * into s from tracking.submissions t where t.id = p_submission for update;
  if not found then
    raise exception 'not_found:submission' using errcode = 'P0002';
  end if;
  select * into snap from tracking.view_snapshots vs where vs.id = p_snapshot and vs.submission_id = p_submission;
  if not found then
    raise exception 'not_found:snapshot' using errcode = 'P0002';
  end if;
  if s.status <> 'tracking' then
    return;  -- flagged/belum approved: Δ menunggu; dihitung dari counted_views saat kembali tracking
  end if;
  select * into c from market.campaigns k where k.id = s.campaign_id;
  v := snap.views;
  base := s.counted_views;
  if snap.is_final and v < base then
    perform finance.correct_down(s.id, snap.id, v);
    update tracking.submissions set counted_views = v where id = s.id;
    return;
  end if;
  if not snap.is_final and snap.taken_at > s.posted_at + make_interval(days => c.view_window_days) then
    return;
  end if;
  crossed := v >= c.min_views;

  perform 1 from finance.reward_pools fp where fp.campaign_id = c.id order by fp.id for update;
  for r in select rr.* from market.rate_rules rr
            where rr.campaign_id = c.id and rr.effective_from <= snap.taken_at
              and (rr.effective_to is null or rr.effective_to > snap.taken_at)
              and (rr.platform is null or rr.platform = s.platform)
            order by rr.pool_id, rr.effective_from, rr.id loop
    select * into ce from finance.clip_earnings x where x.submission_id = s.id and x.rule_id = r.id;
    view_based := r.kind in ('per_1k_views', 'tiered_cpm');
    raw := case
      -- raise_rate menutup rule & membuat versi baru (lineage_id sama): versi yang sudah dibayar = sudah dibayar.
      when r.kind = 'flat_per_post' then
        case when coalesce(ce.once_paid, false) or exists (
                    select 1 from finance.clip_earnings x join market.rate_rules r2 on r2.id = x.rule_id
                     where x.submission_id = s.id and x.once_paid
                       and coalesce(r2.lineage_id, r2.id) = coalesce(r.lineage_id, r.id)) then 0
             else (r.params ->> 'amount')::numeric end
      when r.kind = 'milestone_bonus' then
        case when crossed and not coalesce(ce.once_paid, false) and base < (r.params ->> 'threshold')::numeric
                  and v >= (r.params ->> 'threshold')::numeric then (r.params ->> 'amount')::numeric else 0 end
      when crossed then finance.rule_amount(r.kind, r.params, base, v)
      else 0 end;
    continue when coalesce(raw, 0) <= 0;

    select * into p from finance.reward_pools fp where fp.id = r.pool_id;
    amt := trunc(least(raw, p.max_per_clip - coalesce((select sum(x.amount + x.demand) from finance.clip_earnings x
                                                        where x.submission_id = s.id and x.pool_id = p.id), 0)), 10);
    continue when amt <= 0;
    remaining := p.total - p.allocated;
    in_settle := exists (select 1 from finance.pool_settlements ps where ps.pool_id = p.id);
    if not in_settle and remaining > 0 and remaining * 100 < p.total * pct then
      perform finance.start_settlement(p.id);
      in_settle := true;
    end if;

    if in_settle then
      insert into finance.clip_earnings as x (submission_id, rule_id, pool_id, demand, demand_snapshot, views_from, views_to, once_paid)
      values (s.id, r.id, p.id, amt, snap.id, case when view_based then base end, case when view_based then v end, not view_based)
      on conflict (submission_id, rule_id) do update
        set demand = x.demand + excluded.demand, demand_snapshot = excluded.demand_snapshot,
            views_from = coalesce(x.views_from, excluded.views_from), views_to = coalesce(excluded.views_to, x.views_to),
            once_paid = x.once_paid or excluded.once_paid, updated_at = now();
      continue;
    end if;

    amt := least(amt, remaining);
    continue when amt <= 0;
    entries := entries || jsonb_build_array(
      finance.e(finance.account('campaign_pool', p.id, p.reward_type_id), -amt, 'accrual', snap.id || ':' || r.id),
      finance.e(finance.account('user_wallet', s.user_id, p.reward_type_id), amt, 'accrual', snap.id || ':' || r.id, 'pending'));
    update finance.reward_pools set allocated = allocated + amt where id = p.id;
    insert into finance.clip_earnings as x (submission_id, rule_id, pool_id, amount, views_from, views_to, once_paid)
    values (s.id, r.id, p.id, amt, case when view_based then base end, case when view_based then v end, not view_based)
    on conflict (submission_id, rule_id) do update
      set amount = x.amount + excluded.amount,
          views_from = coalesce(x.views_from, excluded.views_from), views_to = coalesce(excluded.views_to, x.views_to),
          once_paid = x.once_paid or excluded.once_paid, updated_at = now();
    if remaining - amt > 0 and (remaining - amt) * 100 < p.total * pct then
      perform finance.start_settlement(p.id);
    end if;
  end loop;

  if crossed and v > base then
    update tracking.submissions set counted_views = v where id = s.id;
  end if;
  perform finance.post(gen_random_uuid(), entries);
  perform finance.check_exhausted(c.id);
end $function$;

REVOKE ALL ON FUNCTION "api"."bridge_fulfillment_export_accepted"(uuid, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_fulfillment_export_accepted"(uuid, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_fulfillment_export_accepted"(uuid, text) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_fulfillment_export_accepted"(uuid, text) TO "service_role";
