-- Org brand, tim, agency, reward type (F-B01, F-B03, F-B12, F-A07, alur 5). Kode error: kepala api/_helpers.sql.

-- Profil E-01 minimal untuk anggota brand yang belum onboarding (alur 5: FK org_members → profiles). Username sementara
-- m_<12 hex id> bila tidak diberikan/terpakai; ensure_profile memperbaruinya saat onboarding. Profil yang ada tidak diubah.
create function market.ensure_member_profile(p_user uuid, p_username text default null, p_display_name text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  uname text := lower(btrim(p_username));
begin
  if exists (select 1 from market.profiles p where p.id = p_user) then
    return;
  end if;
  if uname is null or uname !~ '^[a-z0-9_.]{3,30}$' or exists (select 1 from market.profiles p where p.username = uname) then
    uname := 'm_' || substr(replace(p_user::text, '-', ''), 1, 12);
  end if;
  while exists (select 1 from market.profiles p where p.username = uname) loop
    uname := 'm_' || substr(md5(random()::text), 1, 12);
  end loop;
  insert into market.profiles (id, username, display_name)
  values (p_user, uname, coalesce(nullif(left(btrim(p_display_name), 50), ''), 'Anggota brand'));
end $$;

-- Keputusan verifikasi org (J-A2): dipakai manage_org (verify/reject) dan record_review target org.
create function market.decide_org(p_org uuid, p_decision text, p_actor uuid, p_reason text, p_message text, p_note text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  o market.organizations;
begin
  select * into o from market.organizations where id = p_org for update;
  if o.id is null then
    perform market.fail('not_found:org', null, 'P0002');
  end if;
  if p_decision = 'approve' then
    update market.organizations set status = 'verified', verified_by = p_actor, verified_at = now() where id = o.id;
  elsif p_decision = 'reject' then
    if nullif(btrim(p_reason), '') is null then
      perform market.fail('invalid:reason', 'penolakan wajib alasan');
    end if;
    if o.status = 'verified' then
      perform market.fail('invalid_state:verified', 'org sudah verified; pakai suspend');
    end if;
  else
    perform market.fail('invalid:decision', coalesce(p_decision, 'null'));
  end if;
  insert into trust.review_decisions (target_type, target_id, actor_id, decision, reason_code, message, note)
  values ('org', o.id, p_actor, p_decision, p_reason, p_message, p_note);
  perform market.notify_org(o.id, null, case p_decision when 'approve' then 'org.verified' else 'org.rejected' end,
                            jsonb_build_object('reason', p_reason, 'message', p_message));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (p_actor, case p_decision when 'approve' then 'org.verify' else 'org.reject' end, 'org:' || o.id,
          jsonb_build_object('status', o.status),
          jsonb_build_object('status', case p_decision when 'approve' then 'verified' else o.status::text end, 'reason', p_reason));
end $$;

-- B1.4: org baru pending_verification, pembuat = brand_owner. Butuh claim consent_ok.brand (ToS brand + privasi terbaru).
-- Badan usaha wajib nama legal + NPWP (15/16 digit); perorangan tanpa data badan (PII di KYC identity pemilik).
create function api.create_org(p_name text, p_org_type text, p_legal_name text default null, p_npwp text default null,
                               p_address text default null, p_is_agency boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  oid uuid;
  npwp text := nullif(regexp_replace(coalesce(p_npwp, ''), '[^0-9]', '', 'g'), '');
begin
  if not coalesce((select (auth.jwt() -> 'consent_ok' ->> 'brand')::boolean), false) then
    perform market.fail('consent_required:brand', 'setujui ToS brand dulu (accounts onboarding?role=brand)');
  end if;
  if not exists (select 1 from market.profiles p where p.id = uid and p.status = 'active') then
    perform market.fail('not_eligible:profile_inactive', 'profil belum ada atau tidak aktif');
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 100 then
    perform market.fail('invalid:name', 'nama 2–100 karakter');
  end if;
  if p_org_type = 'badan' then
    if nullif(btrim(p_legal_name), '') is null then
      perform market.fail('invalid:legal_name', 'badan usaha wajib nama legal');
    end if;
    if npwp is null or npwp !~ '^[0-9]{15,16}$' then
      perform market.fail('invalid:npwp', 'NPWP 15/16 digit');
    end if;
  elsif p_org_type = 'perorangan' then
    if coalesce(p_legal_name, p_npwp, p_address) is not null then
      perform market.fail('invalid:perorangan_pii', 'org perorangan: nama legal/NIK/alamat diambil dari KYC pemilik');
    end if;
  else
    perform market.fail('invalid:org_type', coalesce(p_org_type, 'null'));
  end if;
  insert into market.organizations (name, org_type, legal_name, npwp, address, is_agency, created_by)
  values (btrim(p_name), p_org_type, nullif(btrim(p_legal_name), ''), npwp, nullif(btrim(p_address), ''),
          coalesce(p_is_agency, false), uid)
  returning id into oid;
  insert into market.org_members (org_id, user_id, role, added_by) values (oid, uid, 'brand_owner', uid);
  return oid;
end $$;

-- F-B12 tautan agency → org klien. request: brand_owner/brand_manager langsung di org agency (is_agency). approve: brand_owner
-- langsung org klien (approved_by). revoke/reject: brand_owner langsung klien atau agency. Dicabut = revoked_at (akses hilang).
create function api.link_agency(p_agency uuid, p_client uuid, p_action text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  l market.org_links;
begin
  select * into l from market.org_links where agency_org_id = p_agency and client_org_id = p_client for update;
  if p_action = 'request' then
    if not market.is_direct_member(p_agency, uid, 'brand_owner', 'brand_manager') then
      perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org agency', '42501');
    end if;
    if not exists (select 1 from market.organizations o where o.id = p_agency and o.is_agency) then
      perform market.fail('not_agency', 'org ini bukan agency');
    end if;
    if not exists (select 1 from market.organizations o where o.id = p_client) or p_client = p_agency then
      perform market.fail('not_found:org', null, 'P0002');
    end if;
    if l.agency_org_id is not null and l.revoked_at is null then
      perform market.fail('already_linked', case when l.approved_at is null then 'menunggu persetujuan klien' else 'sudah tertaut' end);
    end if;
    insert into market.org_links (agency_org_id, client_org_id) values (p_agency, p_client)
    on conflict (agency_org_id, client_org_id) do update
      set approved_by = null, approved_at = null, revoked_at = null, created_at = now();
    perform market.notify_org(p_client, array['brand_owner']::market.org_role[], 'agency.link_requested',
                              jsonb_build_object('agency_org_id', p_agency,
                                                 'agency_org_name', (select o.name from market.organizations o where o.id = p_agency)));
  elsif p_action = 'approve' then
    if not market.is_direct_member(p_client, uid, 'brand_owner') then
      perform market.fail('auth:forbidden', 'butuh brand_owner org klien', '42501');
    end if;
    if l.agency_org_id is null or l.revoked_at is not null or l.approved_at is not null then
      perform market.fail('invalid_state:link', 'tidak ada permintaan yang menunggu');
    end if;
    update market.org_links set approved_by = uid, approved_at = now()
     where agency_org_id = p_agency and client_org_id = p_client;
    perform market.notify_org(p_agency, array['brand_owner', 'brand_manager']::market.org_role[], 'agency.link_approved',
                              jsonb_build_object('client_org_id', p_client,
                                                 'client_org_name', (select o.name from market.organizations o where o.id = p_client)));
  elsif p_action in ('revoke', 'reject') then
    if not (market.is_direct_member(p_client, uid, 'brand_owner') or market.is_direct_member(p_agency, uid, 'brand_owner')) then
      perform market.fail('auth:forbidden', 'butuh brand_owner klien atau agency', '42501');
    end if;
    if l.agency_org_id is null or l.revoked_at is not null then
      perform market.fail('invalid_state:link', 'tautan tidak aktif');
    end if;
    update market.org_links set revoked_at = now() where agency_org_id = p_agency and client_org_id = p_client;
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
end $$;

-- B2.1: link undangan anggota (berlaku 7 hari). Token acak dikembalikan sekali; yang disimpan sha256-nya.
-- Hanya brand_owner langsung (bukan lewat agency) yang mengelola anggota.
-- Parameter text (bukan enum member/market): PostgREST meng-cast argumen RPC ke tipe deklarasi, dan role API tidak
-- punya USAGE ke schema internal → enum di parameter = 42501. Cast di dalam fungsi definer.
create function api.create_org_invite(p_org uuid, p_role text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  r market.org_role := p_role::market.org_role;
  uid uuid := market.session_uid();
  tok text;
begin
  if not market.is_direct_member(p_org, uid, 'brand_owner') then
    perform market.fail('auth:forbidden', 'hanya brand_owner org ini', '42501');
  end if;
  if r is null then
    perform market.fail('invalid:role', 'role wajib');
  end if;
  tok := rtrim(translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/', '-_'), '=');
  insert into market.org_invites (org_id, role, token_hash, expires_at, created_by)
  values (p_org, r, sha256(convert_to(tok, 'UTF8')), now() + interval '7 days', uid);
  return tok;
end $$;

-- B2.2: terima undangan → profil dibuat dulu kalau belum ada → E-03. Sudah anggota → kembalikan org tanpa memakai token.
create function api.accept_org_invite(p_token text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  inv market.org_invites;
begin
  select * into inv from market.org_invites where token_hash = sha256(convert_to(coalesce(p_token, ''), 'UTF8')) for update;
  if inv.id is null then
    perform market.fail('not_found:invite', 'link undangan tidak dikenal', 'P0002');
  end if;
  if exists (select 1 from market.org_members m where m.org_id = inv.org_id and m.user_id = uid) then
    return inv.org_id;
  end if;
  if inv.accepted_at is not null then
    perform market.fail('invite_used', 'link undangan sudah dipakai');
  end if;
  if inv.expires_at <= now() then
    perform market.fail('invite_expired', 'link undangan kedaluwarsa; minta link baru');
  end if;
  if exists (select 1 from market.profiles p where p.id = uid and p.status <> 'active') then
    perform market.fail('not_eligible:profile_inactive', 'akun tidak aktif');
  end if;
  perform market.ensure_member_profile(uid);
  insert into market.org_members (org_id, user_id, role, added_by) values (inv.org_id, uid, inv.role, inv.created_by);
  update market.org_invites set accepted_by = uid, accepted_at = now() where id = inv.id;
  return inv.org_id;
end $$;

-- F-A07 admin (admin_ops aal2): verify | reject {reason, message, note} | suspend {reason} | set_fee {mgmt_fee_pct, admin_fee_pct,
-- clipper_fee_pct, instant_withdraw_fee} atau null untuk kembali ke global | add_member {user_id, role, username?, display_name?}
-- (paket managed: user diundang dulu lewat Edge Function identity admin-auth, lalu ditulis di sini). Semua tercatat audit log.
create function api.manage_org(p_org uuid, p_action text, p_params jsonb default '{}') returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  prm jsonb := coalesce(p_params, '{}');
  o market.organizations;
  member_id uuid;
  member_role market.org_role;
  old_role market.org_role;
  new_rule uuid;
begin
  if not ops.has_admin('admin_ops') then
    perform market.fail('auth:forbidden', 'butuh admin_ops/admin_super aal2', '42501');
  end if;
  select * into o from market.organizations where id = p_org;
  if o.id is null then
    perform market.fail('not_found:org', null, 'P0002');
  end if;
  if p_action = 'verify' then
    perform market.decide_org(o.id, 'approve', uid, prm ->> 'reason', prm ->> 'message', prm ->> 'note');
  elsif p_action = 'reject' then
    perform market.decide_org(o.id, 'reject', uid, prm ->> 'reason', prm ->> 'message', prm ->> 'note');
  elsif p_action = 'suspend' then
    if nullif(btrim(prm ->> 'reason'), '') is null then
      perform market.fail('invalid:reason', 'suspend wajib alasan');
    end if;
    update market.organizations set status = 'suspended' where id = o.id;
    perform market.notify_org(o.id, null, 'org.suspended', jsonb_build_object('reason', prm ->> 'reason', 'message', prm ->> 'message'));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'org.suspend', 'org:' || o.id, jsonb_build_object('status', o.status),
            jsonb_build_object('status', 'suspended', 'reason', prm ->> 'reason'));
  elsif p_action = 'set_fee' then
    if jsonb_typeof(prm) = 'null' or prm = '{}'::jsonb or coalesce((prm ->> 'clear')::boolean, false) then
      new_rule := null;
    else
      new_rule := finance.create_fee_rule('org', prm, finance.effective_fee_rule(null, null), uid);
    end if;
    update market.organizations set fee_rule_id = new_rule where id = o.id;
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'org.set_fee', 'org:' || o.id,
            (select to_jsonb(f) from finance.fee_rules f where f.id = o.fee_rule_id),
            (select to_jsonb(f) from finance.fee_rules f where f.id = new_rule));
  elsif p_action = 'add_member' then
    member_id := (prm ->> 'user_id')::uuid;
    member_role := coalesce((prm ->> 'role')::market.org_role, 'brand_owner');
    if member_id is null then
      perform market.fail('invalid:user_id', 'user_id identity wajib');
    end if;
    perform market.ensure_member_profile(member_id, prm ->> 'username', prm ->> 'display_name');
    select m.role into old_role from market.org_members m where m.org_id = o.id and m.user_id = member_id;
    insert into market.org_members (org_id, user_id, role, added_by) values (o.id, member_id, member_role, uid)
    on conflict (org_id, user_id) do update set role = excluded.role;
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'org.add_member', 'org:' || o.id, jsonb_build_object('user_id', member_id, 'role', old_role),
            jsonb_build_object('user_id', member_id, 'role', member_role));
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
end $$;

-- F-B03 reward type custom milik org. p: {id?, owner_org_id, code, name, kind, unit_label, idr_value_per_unit, decimals,
-- fulfillment, recipient_schema, stock, webhook_url, webhook_secret (plaintext → Vault, disimpan ref-nya), fulfillment_margin_pct
-- (admin saja)}. Reward type global (owner NULL) hanya admin_super. Yang sudah dipakai pool: code/kind/nilai Rp/desimal/
-- fulfillment terkunci (dasar fee & ledger).
create function api.save_reward_type(p jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
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
  return rid;
end $$;

-- F-B03 pool kode voucher: hanya reward type code_pool milik org pemanggil; kode duplikat diabaikan (unique). Maks 10.000/panggilan.
create function api.upload_reward_codes(p_reward_type uuid, p_codes text[]) returns int
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  rt market.reward_types;
  n int;
begin
  select * into rt from market.reward_types where id = p_reward_type;
  if rt.id is null then
    perform market.fail('not_found:reward_type', null, 'P0002');
  end if;
  if rt.owner_org_id is null or not ops.is_org_member(rt.owner_org_id, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager pemilik reward type', '42501');
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
  return n;
end $$;

revoke execute on function market.ensure_member_profile(uuid, text, text),
  market.decide_org(uuid, text, uuid, text, text, text) from public;
revoke execute on function api.create_org(text, text, text, text, text, boolean), api.link_agency(uuid, uuid, text),
  api.create_org_invite(uuid, text), api.accept_org_invite(text), api.manage_org(uuid, text, jsonb),
  api.save_reward_type(jsonb), api.upload_reward_codes(uuid, text[]) from public;
grant execute on function api.create_org(text, text, text, text, text, boolean), api.link_agency(uuid, uuid, text),
  api.create_org_invite(uuid, text), api.accept_org_invite(text), api.manage_org(uuid, text, jsonb),
  api.save_reward_type(jsonb), api.upload_reward_codes(uuid, text[]) to authenticated;
