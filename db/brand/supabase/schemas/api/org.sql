-- Org brand, tim, agency (F-B01, F-B12, F-A07, alur 5) — pemilik: project brand. Reward type & fee org ada di admin. Kode error: kepala api/_helpers.sql.

-- Profil E-01 minimal untuk anggota brand yang belum onboarding (alur 5). Profil dimiliki project profil: di sini hanya event
-- profile.ensure (pemilik membuat profil bila belum ada, username sementara m_<hex>; profil yang ada tidak diubah).
create function market.ensure_member_profile(p_user uuid, p_username text default null, p_display_name text default null)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform bus.emit('admin', 'profile.ensure', jsonb_build_object('user_id', p_user, 'username', p_username, 'display_name', p_display_name));
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
  perform bus.emit('admin', 'review.decision', jsonb_build_object('target_type', 'org', 'target_id', o.id, 'actor_id', p_actor,
                    'decision', p_decision, 'reason_code', p_reason, 'message', p_message, 'note', p_note));
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
  -- Replika profil (pemilik di project profil); belum tereplika = baru onboarding, bukan diblokir.
  if exists (select 1 from market.profiles p where p.id = uid
              and not (p.status = 'active' or (p.status = 'suspended' and p.suspended_until <= now()))) then
    perform market.fail('not_eligible:profile_inactive', 'profil belum ada atau tidak aktif');
  end if;
  perform market.ensure_member_profile(uid);
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
    if nullif(btrim(p_address), '') is null then  -- B1.4 / F-B01: alamat badan dipakai di faktur
      perform market.fail('invalid:address', 'badan usaha wajib alamat');
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

-- B2 (policy:core.org-role "owner kelola member"): brand_owner langsung mengubah role, mengeluarkan anggota, atau mencabut
-- undangan yang belum dipakai. Org dikunci supaya dua owner tidak saling menurunkan bersamaan (≥ 1 brand_owner).
create function api.manage_team(p_org uuid, p_action text, p_target uuid, p_role text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  m market.org_members;
  r market.org_role;
begin
  perform 1 from market.organizations where id = p_org for no key update;
  if not market.is_direct_member(p_org, uid, 'brand_owner') then
    perform market.fail('auth:forbidden', 'hanya brand_owner org ini', '42501');
  end if;
  if p_action = 'revoke_invite' then
    delete from market.org_invites where id = p_target and org_id = p_org and accepted_at is null;
    if not found then
      perform market.fail('not_found:invite', null, 'P0002');
    end if;
  elsif p_action in ('set_role', 'remove') then
    select * into m from market.org_members where org_id = p_org and user_id = p_target;
    if m.user_id is null then
      perform market.fail('not_found:member', null, 'P0002');
    end if;
    if p_action = 'set_role' then
      r := p_role::market.org_role;
      if r is null then
        perform market.fail('invalid:role', 'role wajib');
      end if;
    end if;
    if m.role = 'brand_owner' and r is distinct from 'brand_owner'
       and not exists (select 1 from market.org_members o where o.org_id = p_org and o.role = 'brand_owner' and o.user_id <> m.user_id) then
      perform market.fail('last_owner', 'org harus punya minimal satu brand_owner');
    end if;
    if p_action = 'remove' then
      delete from market.org_members where org_id = p_org and user_id = m.user_id;
    else
      update market.org_members set role = r where org_id = p_org and user_id = m.user_id;
    end if;
  else
    perform market.fail('invalid:action', coalesce(p_action, 'null'));
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'org.team.' || p_action, 'org:' || p_org,
          case when m.user_id is not null then jsonb_build_object('user_id', m.user_id, 'role', m.role) else jsonb_build_object('invite_id', p_target) end,
          case when p_action = 'set_role' then jsonb_build_object('role', r) end);
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

-- Halaman undangan accounts (sebelum & sesudah login): token = kapabilitas, jadi pemegang link boleh melihat org + peran.
-- Token tidak dikenal = 0 baris.
create function api.invite_preview(p_token text)
returns table (org_name text, is_agency boolean, role text, expired boolean, used boolean)
language sql stable security definer set search_path = '' as $$
  select o.name, o.is_agency, i.role::text, i.expires_at <= now(), i.accepted_at is not null
    from market.org_invites i join market.organizations o on o.id = i.org_id
   where i.token_hash = sha256(convert_to(coalesce(p_token, ''), 'UTF8'));
$$;
revoke execute on function api.invite_preview(text) from public;
grant execute on function api.invite_preview(text) to anon, authenticated;

-- F-A07 admin (admin_ops aal2): verify | reject {reason, message, note} | suspend {reason} | add_member {user_id, role, username?, display_name?}
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



-- B1.5 cabang ditolak / F-B01: brand_owner memperbaiki data org. Nama legal, NPWP, atau alamat berubah pada org verified →
-- verifikasi ulang (pending_verification, masuk antrean admin lagi); org yang ditolak tetap pending = sudah diajukan ulang.
create function api.update_org(p_org uuid, p_name text, p_legal_name text default null, p_npwp text default null,
                               p_address text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  o market.organizations;
  v_npwp text := nullif(regexp_replace(coalesce(p_npwp, ''), '[^0-9]', '', 'g'), '');
  legal_changed boolean;
begin
  select * into o from market.organizations where id = p_org for no key update;
  if not market.is_direct_member(p_org, uid, 'brand_owner') then
    perform market.fail('auth:forbidden', 'hanya brand_owner org ini', '42501');
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 100 then
    perform market.fail('invalid:name', 'nama 2–100 karakter');
  end if;
  if o.org_type = 'badan' then
    if nullif(btrim(p_legal_name), '') is null then
      perform market.fail('invalid:legal_name', 'badan usaha wajib nama legal');
    end if;
    if v_npwp is null or v_npwp !~ '^[0-9]{15,16}$' then
      perform market.fail('invalid:npwp', 'NPWP 15/16 digit');
    end if;
    if nullif(btrim(p_address), '') is null then
      perform market.fail('invalid:address', 'badan usaha wajib alamat');
    end if;
  elsif coalesce(p_legal_name, p_npwp, p_address) is not null then
    perform market.fail('invalid:perorangan_pii', 'org perorangan: nama legal/NIK/alamat diambil dari KYC pemilik');
  end if;
  legal_changed := o.org_type = 'badan' and (o.legal_name is distinct from btrim(p_legal_name) or o.npwp is distinct from v_npwp
                                             or o.address is distinct from btrim(p_address));
  update market.organizations
     set name = btrim(p_name), legal_name = nullif(btrim(p_legal_name), ''), npwp = v_npwp, address = nullif(btrim(p_address), ''),
         updated_at = now(),
         status = case when legal_changed and status = 'verified' then 'pending_verification' else status end,
         verified_at = case when legal_changed and status = 'verified' then null else verified_at end,
         verified_by = case when legal_changed and status = 'verified' then null else verified_by end
   where id = o.id;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'org.update', 'org:' || o.id,
          jsonb_build_object('name', o.name, 'legal_name', o.legal_name, 'npwp', o.npwp, 'address', o.address, 'status', o.status),
          jsonb_build_object('name', btrim(p_name), 'legal_name', nullif(btrim(p_legal_name), ''), 'npwp', v_npwp,
                             'address', nullif(btrim(p_address), ''), 'reverify', legal_changed));
end $$;

revoke execute on function market.ensure_member_profile(uuid, text, text),
  market.decide_org(uuid, text, uuid, text, text, text) from public;
revoke execute on function api.create_org(text, text, text, text, text, boolean), api.link_agency(uuid, uuid, text),
  api.create_org_invite(uuid, text), api.accept_org_invite(text), api.manage_org(uuid, text, jsonb),
  api.update_org(uuid, text, text, text, text),
  api.manage_team(uuid, text, uuid, text) from public;
grant execute on function api.create_org(text, text, text, text, text, boolean), api.link_agency(uuid, uuid, text),
  api.create_org_invite(uuid, text), api.accept_org_invite(text), api.manage_org(uuid, text, jsonb),
  api.update_org(uuid, text, text, text, text),
  api.manage_team(uuid, text, uuid, text) to authenticated;
