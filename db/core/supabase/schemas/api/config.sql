-- Config admin (F-A04, F-A09, F-A11) & broadcast (F-A12). Semua perubahan tercatat ops.audit_logs sebelum/sesudah.
-- Kunci api.update_config:
--   <kunci ops.settings yang sudah ada>  admin_super; public.home.banners boleh admin_ops; auth.* dikunci (issuer = Fase 0)
--                                        nilai baru harus bertipe JSON sama dengan nilai lama
--   categories.upsert   {id, name_id, name_en, sort?, active?}               admin_ops
--   campaign.pin        {campaign_id, rank (≥ 1 | null), until (| null)}     admin_ops   (null + null = lepas pin)
--   fee_rules.global    {mgmt_fee_pct?, admin_fee_pct?, clipper_fee_pct?, instant_withdraw_fee?}   admin_super
--   fee_rules.org       {org_id, ...pct | clear: true}                       admin_ops   (sama dengan manage_org set_fee)
--   fee_rules.campaign  {campaign_id, ...pct | clear: true}                  admin_ops   (override builder F-A03)
create function api.update_config(p_key text, p_value jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  v jsonb := coalesce(p_value, 'null');
  old jsonb;
  new jsonb;
  act text;
  tgt text;
  rid uuid;
  cid uuid;
begin
  if p_key in ('categories.upsert', 'campaign.pin', 'fee_rules.org', 'fee_rules.campaign', 'public.home.banners') then
    if not ops.has_admin('admin_ops') then
      perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
    end if;
  elsif not ops.has_admin('admin_super') then
    perform market.fail('auth:forbidden', 'butuh admin_super aal2', '42501');
  end if;

  if p_key = 'categories.upsert' then
    if coalesce(v ->> 'id', '') !~ '^[a-z0-9-]{2,30}$' or nullif(btrim(v ->> 'name_id'), '') is null
       or nullif(btrim(v ->> 'name_en'), '') is null then
      perform market.fail('invalid:category', 'id (a-z0-9-), name_id, name_en wajib');
    end if;
    select to_jsonb(x) into old from market.categories x where x.id = v ->> 'id';
    insert into market.categories as k (id, name_id, name_en, sort, active)
    values (v ->> 'id', btrim(v ->> 'name_id'), btrim(v ->> 'name_en'), coalesce((v ->> 'sort')::smallint, 0),
            coalesce((v ->> 'active')::boolean, true))
    on conflict (id) do update set name_id = excluded.name_id, name_en = excluded.name_en,
      sort = case when v ? 'sort' then excluded.sort else k.sort end,
      active = case when v ? 'active' then excluded.active else k.active end;
    select to_jsonb(x) into new from market.categories x where x.id = v ->> 'id';
    act := 'config.category'; tgt := 'category:' || (v ->> 'id');

  elsif p_key = 'campaign.pin' then
    cid := (v ->> 'campaign_id')::uuid;
    if (v ->> 'rank')::int < 1 then
      perform market.fail('invalid:rank', 'rank ≥ 1');
    end if;
    select jsonb_build_object('pinned_rank', c.pinned_rank, 'pinned_until', c.pinned_until) into old
      from market.campaigns c where c.id = cid for update;
    if old is null then
      perform market.fail('not_found:campaign', null, 'P0002');
    end if;
    update market.campaigns set pinned_rank = (v ->> 'rank')::smallint, pinned_until = (v ->> 'until')::timestamptz where id = cid;
    new := jsonb_build_object('pinned_rank', v -> 'rank', 'pinned_until', v -> 'until');
    act := 'config.pin'; tgt := 'campaign:' || cid;

  elsif p_key = 'fee_rules.global' then
    select to_jsonb(f), f.id into old, rid from finance.fee_rules f where f.scope = 'global' for update;
    if rid is null then
      perform market.fail('config:fee_rule_missing', 'fee rule global belum ada (seed)');
    end if;
    update finance.fee_rules set
      mgmt_fee_pct = coalesce(market.jnum(v -> 'mgmt_fee_pct'), mgmt_fee_pct),
      admin_fee_pct = coalesce(market.jnum(v -> 'admin_fee_pct'), admin_fee_pct),
      clipper_fee_pct = coalesce(market.jnum(v -> 'clipper_fee_pct'), clipper_fee_pct),
      instant_withdraw_fee = case when v ? 'instant_withdraw_fee' then market.jnum(v -> 'instant_withdraw_fee') else instant_withdraw_fee end
     where id = rid;
    select to_jsonb(f) into new from finance.fee_rules f where f.id = rid;
    act := 'config.fee_rule'; tgt := 'fee_rule:global';

  elsif p_key in ('fee_rules.org', 'fee_rules.campaign') then
    if p_key = 'fee_rules.org' then
      cid := (v ->> 'org_id')::uuid;
      select to_jsonb(f) into old from market.organizations o left join finance.fee_rules f on f.id = o.fee_rule_id where o.id = cid;
      if not exists (select 1 from market.organizations o where o.id = cid) then
        perform market.fail('not_found:org', null, 'P0002');
      end if;
    else
      cid := (v ->> 'campaign_id')::uuid;
      if not exists (select 1 from market.campaigns c where c.id = cid) then
        perform market.fail('not_found:campaign', null, 'P0002');
      end if;
      select to_jsonb(f) into old from market.campaigns c left join finance.fee_rules f on f.id = c.fee_rule_id where c.id = cid;
    end if;
    if not coalesce((v ->> 'clear')::boolean, false) then
      rid := finance.create_fee_rule(case p_key when 'fee_rules.org' then 'org' else 'campaign' end,
                                     v - 'org_id' - 'campaign_id',
                                     case p_key when 'fee_rules.org' then finance.effective_fee_rule(null, null)
                                                else finance.effective_fee_rule((select c.org_id from market.campaigns c where c.id = cid), null) end,
                                     uid);
    end if;
    if p_key = 'fee_rules.org' then
      update market.organizations set fee_rule_id = rid where id = cid;
    else
      update market.campaigns set fee_rule_id = rid where id = cid;
    end if;
    select to_jsonb(f) into new from finance.fee_rules f where f.id = rid;
    act := 'config.fee_rule'; tgt := case p_key when 'fee_rules.org' then 'org:' else 'campaign:' end || cid;

  else
    if p_key like 'auth.%' then
      perform market.fail('config_key_locked', 'issuer identity diubah lewat migration Fase 0, bukan dari admin');
    end if;
    select s.value into old from ops.settings s where s.key = p_key for update;
    if old is null then
      perform market.fail('invalid:config_key', coalesce(p_key, 'null'));
    end if;
    if jsonb_typeof(v) <> jsonb_typeof(old) then
      perform market.fail('invalid:value_type', format('%s harus %s', p_key, jsonb_typeof(old)));
    end if;
    update ops.settings set value = v, updated_by = uid, updated_at = now() where key = p_key;
    new := v;
    act := 'config.update'; tgt := 'settings:' || p_key;
  end if;

  insert into ops.audit_logs (actor_id, action, target, before, after) values (uid, act, tgt, old, new);
end $$;

-- A6.1: jadwalkan broadcast; dikirim job broadcast-dispatch (ops.dispatch_broadcasts). Segmen: {platforms, min_trust_score,
-- max_trust_score, kyc: approved|not_approved, active_days}. p_kind security (admin_super): pemberitahuan kebocoran data ke
-- semua user (§16), tanpa segmen, selalu in-app + email transaksional (tidak terhalang berhenti langganan promosi).
create function api.send_broadcast(p_title text, p_body text, p_segment jsonb default '{}', p_channels text[] default '{in_app}',
                                   p_scheduled_at timestamptz default null, p_kind text default 'promo') returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  seg jsonb := coalesce(p_segment, '{}');
  k text;
  bid uuid;
begin
  if not ops.has_admin('admin_ops') then
    perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
  end if;
  if coalesce(p_kind, '') not in ('promo', 'security') then
    perform market.fail('invalid:kind', coalesce(p_kind, 'null'));
  end if;
  if p_kind = 'security' then
    if not ops.has_admin('admin_super') then
      perform market.fail('auth:forbidden', 'pemberitahuan keamanan butuh admin_super aal2', '42501');
    end if;
    if seg <> '{}' then
      perform market.fail('invalid:segment', 'pemberitahuan keamanan ke semua user');
    end if;
  end if;
  if jsonb_typeof(seg) <> 'object' then
    perform market.fail('invalid:segment', 'segmen harus object');
  end if;
  for k in select jsonb_object_keys(seg) loop
    if k not in ('platforms', 'min_trust_score', 'max_trust_score', 'kyc', 'active_days') then
      perform market.fail('invalid:segment', k);
    end if;
  end loop;
  if seg ? 'platforms' and (jsonb_typeof(seg -> 'platforms') <> 'array'
     or exists (select 1 from jsonb_array_elements_text(seg -> 'platforms') x
                where x not in (select unnest(enum_range(null::market.platform))::text))) then
    perform market.fail('invalid:segment', 'platforms');
  end if;
  if seg ? 'kyc' and seg ->> 'kyc' not in ('approved', 'not_approved') then
    perform market.fail('invalid:segment', 'kyc');
  end if;
  if (seg ? 'min_trust_score' and market.jnum(seg -> 'min_trust_score') is null)
     or (seg ? 'max_trust_score' and market.jnum(seg -> 'max_trust_score') is null)
     or (seg ? 'active_days' and coalesce(market.jnum(seg -> 'active_days'), 0) <= 0) then
    perform market.fail('invalid:segment', 'angka segmen');
  end if;
  insert into ops.broadcasts (title, body, segment, channels, created_by, scheduled_at, kind)
  values (btrim(p_title), btrim(p_body), seg,
          case when p_kind = 'security' then (select array_agg(distinct c) from unnest(coalesce(p_channels, '{}') || array['in_app', 'email']) c)
               else coalesce(p_channels, '{in_app}') end,
          uid, coalesce(p_scheduled_at, now()), p_kind)
  returning id into bid;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'broadcast.create', 'broadcast:' || bid, null,
          jsonb_build_object('title', btrim(p_title), 'segment', seg, 'channels', p_channels, 'scheduled_at', p_scheduled_at, 'kind', p_kind));
  return bid;
end $$;

revoke execute on function api.update_config(text, jsonb), api.send_broadcast(text, text, jsonb, text[], timestamptz, text) from public;
grant execute on function api.update_config(text, jsonb), api.send_broadcast(text, text, jsonb, text[], timestamptz, text) to authenticated;
