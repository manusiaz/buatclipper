SET local check_function_bodies = off;

DROP TRIGGER "campaigns_brief_frozen" ON "market"."campaigns";

DROP TRIGGER "profiles_replicate" ON "market"."profiles";

ALTER TABLE "market"."campaigns"
  DROP CONSTRAINT "campaigns_template_stays_draft";

DROP FUNCTION "api"."duplicate_campaign"(uuid, boolean);

DROP FUNCTION "api"."invite_to_campaign"(uuid, text[]);

DROP FUNCTION "market"."freeze_brief"();

ALTER TABLE "market"."campaigns"
  ADD COLUMN "content_version" integer NOT NULL DEFAULT 1;

ALTER TABLE "market"."campaigns"
  ADD COLUMN "submitted_version" integer;

CREATE OR REPLACE FUNCTION api.copy_campaign_economics (
  p_from uuid,
  p_to   uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  c market.campaigns;
  d market.campaigns;
  pl record;
  npid uuid;
begin
  select * into c from market.campaigns where id = p_from;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  select * into d from market.campaigns where id = p_to for update;
  if d.id is null then
    perform market.fail('retry:replica_lag', 'salinan dari brand belum tiba; ulangi');
  end if;
  if d.org_id <> c.org_id or d.status <> 'draft' or exists (select 1 from finance.reward_pools x where x.campaign_id = d.id) then
    perform market.fail('invalid:target', 'tujuan harus draft baru org yang sama');
  end if;
  update market.campaigns set fee_rule_id = c.fee_rule_id, view_window_days = c.view_window_days where id = d.id;
  for pl in select * from finance.reward_pools x where x.campaign_id = c.id order by x.id loop
    insert into finance.reward_pools (campaign_id, reward_type_id, total, max_per_clip)
    values (d.id, pl.reward_type_id, pl.total, pl.max_per_clip)
    returning id into npid;
    insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, platform, params)
    select d.id, r.kind, r.reward_type_id, npid, r.platform, r.params from market.rate_rules r
     where r.pool_id = pl.id and r.effective_to is null;
  end loop;
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
  cols constant text[] := array['start_at', 'submit_deadline', 'view_window_days'];
  c market.campaigns;
  org market.organizations;
  patch jsonb := '{}';
  k text;
  e jsonb;
  pid uuid;
  rt market.reward_types;
  kept uuid[] := '{}';
  pool_map jsonb := '{}';
  plat market.platform;
  paid_sub numeric;
  pools_before jsonb;
  send_to_brand boolean;
  inv finance.invoices;
begin
  if jsonb_typeof(p) <> 'object' then
    perform market.fail('invalid:payload', 'p_campaign harus object');
  end if;
  for k in select jsonb_object_keys(p) loop
    if not (k = any (cols) or k in ('id', 'content_version', 'pools', 'rules', 'fee_rule')) then
      perform market.fail('invalid:unknown_key', k);
    end if;
  end loop;
  if not p ? 'id' then
    perform market.fail('invalid:id', 'campaign dibuat di project brand dulu');
  end if;
  if p_submit and not p ? 'content_version' then
    perform market.fail('invalid:content_version', 'pengajuan wajib menyebut versi isi');
  end if;
  select * into c from market.campaigns where id = (p ->> 'id')::uuid for update;
  if c.id is null or c.content_version < coalesce((p ->> 'content_version')::int, 0) then
    perform market.fail('retry:replica_lag', 'isi campaign dari brand belum tiba; ulangi');
  end if;
  if is_admin then  -- F-A11: builder admin (paket managed) tercatat; gagal di bawah = ikut di-rollback
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'campaign.save', 'campaign:' || c.id, jsonb_build_object('status', c.status),
            jsonb_build_object('submit', p_submit, 'keys', (select jsonb_agg(k2 order by k2) from jsonb_object_keys(p) k2)));
  end if;
  select * into org from market.organizations where id = c.org_id;
  is_brand := ops.is_org_member(org.id, 'brand_owner', 'brand_manager');
  if not (is_brand or is_admin) or (p ? 'fee_rule' and not is_admin) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org atau admin_ops aal2', '42501');
  end if;
  if org.status = 'suspended' then
    perform market.fail('org_suspended', 'org disuspend');
  end if;
  if c.status not in ('draft', 'rejected') then
    if p_submit or exists (select 1 from jsonb_object_keys(p) x where x not in ('id', 'content_version')) then
      perform market.fail('campaign_locked', format('campaign %s: jadwal, pool, dan rule terkunci', c.status));
    end if;
    return c.id;
  end if;

  for k in select x from jsonb_object_keys(p) x where x = any (cols) loop
    patch := patch || jsonb_build_object(k, p -> k);
  end loop;
  if c.status = 'rejected' then
    update market.campaigns set status = 'draft' where id = c.id;
  end if;
  if patch <> '{}' then
    execute format('update market.campaigns t set (%1$s) = (select %1$s from jsonb_populate_record(null::market.campaigns, $1)) '
                   'where t.id = $2', (select string_agg(quote_ident(x), ', ') from jsonb_object_keys(patch) x))
      using patch, c.id;
  end if;
  select * into c from market.campaigns where id = c.id;

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
  if c.content_version <> (p ->> 'content_version')::int then
    perform market.fail('retry:content_changed', 'isi campaign berubah sejak dilihat; muat ulang lalu ajukan');
  end if;
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
  if exists (select 1 from market.rate_rules r where r.campaign_id = c.id and r.platform is not null and not (r.platform = any (c.platforms))) then
    perform market.fail('invalid:rule_platform', 'platform rule tidak ada di campaign');
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
  update market.campaigns set status = 'in_review', submitted_version = c.content_version where id = c.id;
  if paid_sub is null then
    update finance.invoices set status = 'void' where campaign_id = c.id and kind = 'campaign' and status = 'issued';
    inv := finance.issue_invoice(org.id, c.id, 'campaign', finance.campaign_budget_idr(c.id));
  end if;
  return c.id;
end $function$;

CREATE OR REPLACE FUNCTION bus.apply_row (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  t regclass := (p ->> 'table')::regclass;
  pk text[] := bus.pk_columns(t);
  cols text[];
  upd text;
  h regprocedure;
begin
  perform set_config('bus.applying', 'on', true);
  if p ->> 'op' = 'delete' then
    execute format('delete from %s x using jsonb_populate_record(null::%s, $1) k where %s', t, t,
                   (select string_agg(format('x.%1$I = k.%1$I', c), ' and ') from unnest(pk) c))
      using p -> 'key';
  else
    select array_agg(k) into cols from jsonb_object_keys(p -> 'row') k;
    select string_agg(format('%1$I = excluded.%1$I', c), ', ') into upd from unnest(cols) c where not c = any (pk);
    begin
      execute format('insert into %1$s (%2$s) select %2$s from jsonb_populate_record(null::%1$s, $1) on conflict (%3$s) do %4$s',
                     t, (select string_agg(format('%I', c), ', ') from unnest(cols) c),
                     (select string_agg(format('%I', c), ', ') from unnest(pk) c),
                     case when upd is null then 'nothing' else 'update set ' || upd end)
        using p -> 'row';
    exception when not_null_violation then
      -- kolom milik sebagian (mis. status dari admin) untuk baris yang belum/tidak ada di sini: tidak ada yang diperbarui
      perform set_config('bus.applying', 'off', true);
      return;
    end;
  end if;
  perform set_config('bus.applying', 'off', true);
  h := to_regprocedure(format('bus_in.%s_%s_applied(text, jsonb)', split_part(p ->> 'table', '.', 1), split_part(p ->> 'table', '.', 2)));
  if h is not null then
    execute format('select %s($1, $2)', h::regproc) using p ->> 'op', coalesce(p -> 'row', p -> 'key');
  end if;
end $function$;

CREATE OR REPLACE FUNCTION bus.resync (
  p_table  regclass,
  p_target text
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  cols text[];
  pk text[] := bus.pk_columns(p_table);
  r jsonb;
  n int := 0;
begin
  select string_to_array(split_part(a, ':', 2), ',') into cols
    from pg_trigger tg
   cross join lateral unnest(array_remove(string_to_array(encode(tg.tgargs, 'escape'), '\000'), '')) a
   where tg.tgrelid = p_table and tg.tgfoid = 'bus.replicate()'::regprocedure and split_part(a, ':', 1) = p_target;
  if cols is null then
    raise exception 'bus_no_replica:%:%', p_table, p_target using errcode = 'P0001';
  end if;
  for r in execute format('select to_jsonb(t) from %s t', p_table) loop
    perform bus.emit(p_target, 'rep.row', jsonb_build_object('table', p_table::text, 'op', 'upsert',
      'key', (select jsonb_object_agg(k, r -> k) from unnest(pk) k),
      'row', (select jsonb_object_agg(c, r -> c) from unnest(cols || pk) c)));
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION bus_in.market_campaigns_applied (
  p_op  text,
  p_row jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  c market.campaigns;
begin
  if p_op <> 'upsert' then
    return;
  end if;
  select * into c from market.campaigns where id = (p_row ->> 'id')::uuid for update;
  if c.id is null or c.content_version <= coalesce(c.submitted_version, 0) then
    return;
  end if;
  if c.status = 'rejected' then
    update market.campaigns set status = 'draft' where id = c.id;
  elsif c.status = 'in_review' then
    update market.campaigns set status = 'rejected' where id = c.id;
    update market.campaigns set status = 'draft' where id = c.id;
    update finance.invoices set status = 'void' where campaign_id = c.id and kind = 'campaign' and status = 'issued';
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'campaign.rejected',
                              jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'reason', 'content_changed'));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (null, 'campaign.resubmit_required', 'campaign:' || c.id, jsonb_build_object('submitted_version', c.submitted_version),
            jsonb_build_object('content_version', c.content_version));
  elsif c.status <> 'draft' then
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (null, 'campaign.content_drift', 'campaign:' || c.id, jsonb_build_object('submitted_version', c.submitted_version),
            jsonb_build_object('content_version', c.content_version, 'status', c.status));
  end if;
end $function$;

CREATE OR REPLACE FUNCTION bus_in.notify_user (
  p jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  body jsonb := coalesce(p -> 'payload', '{}');
begin
  if p ->> 'event' = 'campaign.invited' and body ? 'campaign_id' then
    body := body || jsonb_build_object('rate_per_1k', market.rate_per_1k((body ->> 'campaign_id')::uuid));
  end if;
  perform ops.enqueue_notification((p ->> 'user_id')::uuid, p ->> 'event', body, coalesce((p ->> 'email')::boolean, true));
end $function$;

CREATE TRIGGER campaigns_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('brand:status,start_at,submit_deadline,view_window_days,pinned_until');

CREATE TRIGGER categories_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.categories
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('brand:name_id,name_en,sort,active');

CREATE TRIGGER profiles_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.profiles
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('brand:username,display_name,avatar_path,status,suspended_until,trust_score');

REVOKE ALL ON FUNCTION "api"."copy_campaign_economics"(uuid, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."copy_campaign_economics"(uuid, uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."copy_campaign_economics"(uuid, uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."copy_campaign_economics"(uuid, uuid) TO "postgres";

REVOKE ALL ON FUNCTION "bus"."resync"(regclass, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."resync"(regclass, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."resync"(regclass, text) TO "postgres";

REVOKE ALL ON FUNCTION "bus_in"."market_campaigns_applied"(text, jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."market_campaigns_applied"(text, jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."market_campaigns_applied"(text, jsonb) TO "postgres";
