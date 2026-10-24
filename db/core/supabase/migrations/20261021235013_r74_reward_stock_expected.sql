SET local check_function_bodies = off;

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
                                   'fulfillment', 'recipient_schema', 'stock', 'stock_expected', 'webhook_url', 'webhook_secret',
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
    -- Stok dipotong/dikembalikan sistem (invoice lunas, campaign selesai): form lama tidak boleh menimpanya (R74).
    if p ? 'stock' and (not p ? 'stock_expected' or cur.stock is distinct from market.jnum(p -> 'stock_expected')) then
      perform market.fail('stock_stale', 'stok berubah sejak form dibuka');
    end if;
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
