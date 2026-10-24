SET local check_function_bodies = off;

SELECT cron.unschedule('reconcile-daily');

CREATE OR REPLACE FUNCTION api.approve_payout_batch (
  p_batch uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  update finance.payout_batches set approved_by = (select auth.uid()), status = 'approved'
   where id = p_batch and status = 'draft';
  if not found then
    raise exception 'batch_not_draft' using errcode = 'P0001';
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout_batch.approve', 'payout_batch:' || p_batch, '{"status": "draft"}', '{"status": "approved"}');
end $function$;

CREATE OR REPLACE FUNCTION api.approve_refund (
  p_refund uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  update finance.org_refunds set status = 'approved', approved_by = (select auth.uid()) where id = p_refund and status = 'requested';
  if not found then
    raise exception 'invalid_state:refund' using errcode = 'P0001';
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'refund.approve', 'refund:' || p_refund, '{"status": "requested"}', '{"status": "approved"}');
end $function$;

CREATE OR REPLACE FUNCTION api.confirm_invoice_payment (
  p_invoice uuid,
  p_amount  numeric,
  p_paid_at timestamp with time zone,
  p_ref     text,
  p_channel text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  inv finance.invoices;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into inv from finance.invoices i where i.id = p_invoice for update;
  if not found then
    raise exception 'not_found:invoice' using errcode = 'P0002';
  end if;
  if inv.status = 'paid' and inv.payment_ref = p_ref then
    return;  -- replay konfirmasi yang sama
  end if;
  if inv.status <> 'issued' then
    raise exception 'invalid_state:%', inv.status using errcode = 'P0001';
  end if;
  if p_amount is distinct from inv.total then
    raise exception 'amount_mismatch' using errcode = 'P0001', detail = format('invoice %s, dibayar %s', inv.total, p_amount);
  end if;
  if p_ref is null or btrim(p_ref) = '' or p_channel is null or p_channel not in ('qris', 'transfer') then
    raise exception 'invalid:payment' using errcode = 'P0001';
  end if;
  if exists (select 1 from finance.invoices i where i.payment_ref = btrim(p_ref)) then
    raise exception 'duplicate_payment_ref' using errcode = '23505';
  end if;
  if inv.kind = 'campaign' and exists (select 1 from finance.invoices i where i.campaign_id = inv.campaign_id and i.kind = 'campaign'
                                                                        and i.status = 'paid') then
    raise exception 'campaign_already_funded' using errcode = 'P0001';
  end if;

  update finance.invoices set status = 'paid', payment_channel = p_channel, payment_ref = btrim(p_ref), paid_amount = p_amount,
         paid_at = coalesce(p_paid_at, now()), confirmed_by = (select auth.uid())
   where id = inv.id;
  perform finance.settle_invoice(inv, finance.account('bank_clearing', null, finance.idr()));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'invoice.confirm_payment', 'invoice:' || inv.id, jsonb_build_object('status', inv.status),
          jsonb_build_object('status', 'paid', 'amount', p_amount, 'ref', btrim(p_ref), 'channel', p_channel, 'paid_at', p_paid_at));
end $function$;

CREATE OR REPLACE FUNCTION api.create_payout_batch (
  p_cutoff timestamp with time zone
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  bid uuid;
  n int;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  insert into finance.payout_batches (created_by, cutoff_at) values ((select auth.uid()), coalesce(p_cutoff, now()))
  returning id into bid;
  update finance.payouts set batch_id = bid
   where status = 'requested' and channel = 'batch' and batch_id is null and created_at <= coalesce(p_cutoff, now());
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'batch_empty' using errcode = 'P0001';
  end if;
  update finance.payout_batches b set count = n,
         total = (select sum(p.amount - p.fee) from finance.payouts p where p.batch_id = bid)
   where b.id = bid;
  insert into ops.audit_logs (actor_id, action, target, after)
  values ((select auth.uid()), 'payout_batch.create', 'payout_batch:' || bid,
          (select jsonb_build_object('count', b.count, 'total', b.total, 'cutoff', p_cutoff) from finance.payout_batches b where b.id = bid));
  return bid;
end $function$;

CREATE OR REPLACE FUNCTION api.mark_batch_paid (
  p_batch   uuid,
  p_results jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  b finance.payout_batches;
  x record;
  po finance.payouts;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into b from finance.payout_batches pb where pb.id = p_batch for update;
  if not found or b.status not in ('exported', 'paid', 'closed') then
    raise exception 'batch_not_exported' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_results) is distinct from 'array' then
    raise exception 'invalid:results' using errcode = 'P0001';
  end if;
  for x in select * from jsonb_to_recordset(p_results) r(payout_id uuid, status text, bank_ref text) loop
    select * into po from finance.payouts p where p.id = x.payout_id and p.batch_id = p_batch for update;
    if not found then
      raise exception 'payout_not_in_batch' using errcode = 'P0001';
    end if;
    continue when (po.status = 'paid' and x.status = 'paid') or (po.status = 'returned' and x.status = 'failed');
    if po.status <> 'processing' and not (po.status = 'paid' and x.status = 'failed') then  -- paid → failed = retur bank
      raise exception 'payout_not_in_export' using errcode = 'P0001';
    end if;
    if x.status = 'paid' then
      update finance.payouts set status = 'paid', paid_at = now(), bank_ref = x.bank_ref where id = po.id;
      perform ops.enqueue_notification(po.user_id, 'payout.paid', finance.amount_ref(finance.idr(), po.amount - po.fee)
                                       || jsonb_build_object('payout_id', po.id, 'channel', po.channel));
    elsif x.status = 'failed' then
      update finance.payouts set bank_ref = x.bank_ref where id = po.id;
      perform finance.return_payout(po.id);
    else
      raise exception 'invalid:result_status' using errcode = 'P0001';
    end if;
  end loop;
  if not exists (select 1 from finance.payouts p where p.batch_id = p_batch and p.status = 'processing') and b.status = 'exported' then
    update finance.payout_batches set status = 'paid', executed_at = now() where id = p_batch;
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout_batch.mark_paid', 'payout_batch:' || p_batch, jsonb_build_object('status', b.status),
          jsonb_build_object('results', p_results));
end $function$;

CREATE OR REPLACE FUNCTION api.resolve_alert (
  p_id bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if not ops.has_admin() then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  update ops.alerts set resolved_at = now(), resolved_by = (select auth.uid()) where id = p_id and resolved_at is null;
  if not found then
    raise exception 'not_found:alert' using errcode = 'P0002';
  end if;
  insert into ops.audit_logs (actor_id, action, target, after) values ((select auth.uid()), 'alert.resolve', 'alert:' || p_id, null);
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
end $function$;

CREATE OR REPLACE FUNCTION api.save_reward_type (
  p jsonb
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  cur market.reward_types;
  org uuid;
  rid uuid;
  sec uuid;
  k text;
  allowed constant text[] := array['id', 'owner_org_id', 'code', 'name', 'kind', 'unit_label', 'idr_value_per_unit', 'decimals',
                                   'fulfillment', 'recipient_schema', 'stock', 'webhook_url', 'webhook_secret',
                                   'fulfillment_margin_pct'];
begin
  if jsonb_typeof(p) is distinct from 'object' then
    perform market.fail('invalid:payload', 'p harus object');
  end if;
  for k in select jsonb_object_keys(p) loop
    if not (k = any (allowed)) then
      perform market.fail('invalid:unknown_key', k);
    end if;
  end loop;
  if p ? 'id' then
    select * into cur from market.reward_types where id = (p ->> 'id')::uuid for update;
    if cur.id is null then
      perform market.fail('not_found:reward_type', null, 'P0002');
    end if;
    org := cur.owner_org_id;
  else
    org := (p ->> 'owner_org_id')::uuid;
  end if;
  if org is null then
    if not ops.has_admin('admin_super') then
      perform market.fail('auth:forbidden', 'reward type global hanya admin_super', '42501');
    end if;
  elsif not (ops.is_org_member(org, 'brand_owner', 'brand_manager') or ops.has_admin('admin_ops')) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  if p ? 'fulfillment_margin_pct' and not ops.has_admin('admin_super') then
    perform market.fail('auth:forbidden', 'margin fulfillment diatur admin_super', '42501');
  end if;
  if cur.id is not null and exists (select 1 from finance.reward_pools pl where pl.reward_type_id = cur.id)
     and ((p ? 'code' and upper(p ->> 'code') <> cur.code) or (p ? 'kind' and p ->> 'kind' <> cur.kind)
          or (p ? 'idr_value_per_unit' and market.jnum(p -> 'idr_value_per_unit') <> cur.idr_value_per_unit)
          or (p ? 'decimals' and (p ->> 'decimals')::smallint <> cur.decimals)
          or (p ? 'fulfillment' and p ->> 'fulfillment' <> cur.fulfillment)) then
    perform market.fail('reward_type_in_use', 'sudah dipakai pool; buat reward type baru');
  end if;
  if p ? 'recipient_schema' and jsonb_typeof(p -> 'recipient_schema') <> 'array' then
    perform market.fail('invalid:recipient_schema', 'array field penerima [{key, label, pii}]');
  end if;

  -- Secret webhook (HMAC) ke Vault core lebih dulu (constraint reward_types_webhook_complete); tabel hanya memegang ref.
  rid := coalesce(cur.id, gen_random_uuid());
  sec := cur.webhook_secret_ref;
  if nullif(p ->> 'webhook_secret', '') is not null then
    if sec is null then
      sec := vault.create_secret(p ->> 'webhook_secret', 'reward_webhook:' || rid::text, 'secret webhook reward type');
    else
      perform vault.update_secret(sec, p ->> 'webhook_secret');
    end if;
  end if;

  if cur.id is null then
    insert into market.reward_types (id, owner_org_id, code, name, kind, unit_label, idr_value_per_unit, decimals, fulfillment,
                                     recipient_schema, stock, webhook_url, webhook_secret_ref, fulfillment_margin_pct)
    values (rid, org, upper(btrim(p ->> 'code')), btrim(p ->> 'name'), p ->> 'kind', btrim(p ->> 'unit_label'),
            market.jnum(p -> 'idr_value_per_unit'), coalesce((p ->> 'decimals')::smallint, 0), p ->> 'fulfillment',
            coalesce(p -> 'recipient_schema', '[]'), market.jnum(p -> 'stock'), nullif(btrim(p ->> 'webhook_url'), ''), sec,
            coalesce(market.jnum(p -> 'fulfillment_margin_pct'), 0));
  else
    update market.reward_types set
      code = case when p ? 'code' then upper(btrim(p ->> 'code')) else code end,
      name = case when p ? 'name' then btrim(p ->> 'name') else name end,
      kind = case when p ? 'kind' then p ->> 'kind' else kind end,
      unit_label = case when p ? 'unit_label' then btrim(p ->> 'unit_label') else unit_label end,
      idr_value_per_unit = case when p ? 'idr_value_per_unit' then market.jnum(p -> 'idr_value_per_unit') else idr_value_per_unit end,
      decimals = case when p ? 'decimals' then (p ->> 'decimals')::smallint else decimals end,
      fulfillment = case when p ? 'fulfillment' then p ->> 'fulfillment' else fulfillment end,
      recipient_schema = case when p ? 'recipient_schema' then p -> 'recipient_schema' else recipient_schema end,
      stock = case when p ? 'stock' then market.jnum(p -> 'stock') else stock end,
      webhook_url = case when p ? 'webhook_url' then nullif(btrim(p ->> 'webhook_url'), '') else webhook_url end,
      webhook_secret_ref = sec,
      fulfillment_margin_pct = case when p ? 'fulfillment_margin_pct' then market.jnum(p -> 'fulfillment_margin_pct')
                                    else fulfillment_margin_pct end
     where id = rid;
  end if;
  if ops.has_admin() then
    insert into ops.audit_logs (actor_id, action, target, after)
    values (uid, 'reward_type.save', 'reward_type:' || rid, p - 'webhook_secret');
  end if;
  return rid;
end $function$;

CREATE OR REPLACE FUNCTION api.upload_reward_codes (
  p_reward_type uuid,
  p_codes       text[]
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  rt market.reward_types;
  n int;
begin
  select * into rt from market.reward_types where id = p_reward_type;
  if rt.id is null then
    perform market.fail('not_found:reward_type', null, 'P0002');
  end if;
  -- Brand pemilik reward type, atau admin_ops (F-A10: kode dari brand dikirim ke tim, atau reward type milik platform).
  if not (ops.has_admin('admin_ops')
          or (rt.owner_org_id is not null and ops.is_org_member(rt.owner_org_id, 'brand_owner', 'brand_manager'))) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager pemilik reward type atau admin_ops', '42501');
  end if;
  if rt.fulfillment <> 'code_pool' then
    perform market.fail('invalid:fulfillment', 'reward type ini bukan pool kode');
  end if;
  if coalesce(cardinality(p_codes), 0) > 10000 then
    perform market.fail('invalid:codes', 'maks 10.000 kode per unggahan');
  end if;
  insert into finance.reward_codes (reward_type_id, code, uploaded_by)
  select rt.id, x.code, uid from (select distinct btrim(u) as code from unnest(p_codes) u where btrim(u) <> '') x
  on conflict (reward_type_id, code) do nothing;
  get diagnostics n = row_count;
  if ops.has_admin('admin_ops') then
    insert into ops.audit_logs (actor_id, action, target, after)
    values (uid, 'reward_codes.upload', 'reward_type:' || rt.id, jsonb_build_object('inserted', n));
  end if;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION finance.reconcile_ledger()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  idr uuid := finance.idr();
  issues jsonb;
begin
  select jsonb_strip_nulls(jsonb_build_object(
    'pool_cache', (select jsonb_agg(rp.id) from finance.reward_pools rp
                    where rp.allocated <> coalesce((select -sum(e.amount) from finance.ledger_entries e
                                                      join finance.ledger_accounts a on a.id = e.account_id
                                                     where a.owner_type = 'campaign_pool' and a.owner_id = rp.id
                                                       and e.ref_type in ('accrual', 'reversal', 'release')), 0)),
    'negative_wallet', (select jsonb_agg(a.id) from finance.ledger_accounts a
                         where a.owner_type = 'user_wallet'
                           and (select coalesce(sum(e.amount), 0) from finance.ledger_entries e
                                 where e.account_id = a.id and e.state in ('pending', 'available')) < 0),
    'invoice_unposted', (select jsonb_agg(i.id) from finance.invoices i
                          where i.status = 'paid'
                            and not exists (select 1 from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                                             where e.ref_type = 'invoice_payment' and e.ref_id = i.id::text and e.amount = -i.total
                                               and a.owner_type in ('bank_clearing', 'org_credit') and a.reward_type_id = idr)),
    'journal_without_invoice', (select jsonb_agg(distinct e.ref_id) from finance.ledger_entries e
                                 where e.ref_type = 'invoice_payment'
                                   and not exists (select 1 from finance.invoices i where i.id::text = e.ref_id and i.status = 'paid'))))
    into issues;
  if issues <> '{}' then
    perform ops.raise_alert('reconcile.ledger', 'critical', issues);
  end if;
  return issues;
end $function$;

REVOKE ALL ON FUNCTION "finance"."reconcile_ledger"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "finance"."reconcile_ledger"() FROM "postgres";

GRANT EXECUTE ON FUNCTION "finance"."reconcile_ledger"() TO "postgres";

SELECT
  cron.schedule_in_database('reconcile-daily', '0 18 * * *', 'select finance.reconcile_ledger(); select ops.invoke_function(''bridge'', ''{"action":"reconcile_ids"}'')',
  'postgres', NULL, true);
