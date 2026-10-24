-- Catat atau cabut consent milik sendiri (E-28). ToS & privasi hanya menerima versi terbaru yang terbit (E-31),
-- supaya tidak ada persetujuan atas versi yang belum pernah dilihat user.
-- Parameter text (bukan enum member/market): PostgREST meng-cast argumen RPC ke tipe deklarasi, dan role API tidak
-- punya USAGE ke schema internal → enum di parameter = 42501. Cast di dalam fungsi definer.
create function api.record_consent(p_kind text, p_version text default null, p_granted boolean default true)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  k member.consent_kind := p_kind::member.consent_kind;
  uid uuid := (select auth.uid());
  v text;
begin
  if uid is null then
    raise exception 'login dulu' using errcode = '42501';
  end if;
  if not p_granted then
    update member.consents set revoked_at = now()
     where user_id = uid and kind = k and revoked_at is null;
    return;
  end if;
  if k in ('tos_clipper', 'tos_brand', 'privacy') then
    select max(lv.version) into v from member.legal_versions lv where lv.kind = k and lv.published_at <= now();
    if v is null or p_version is distinct from v then
      raise exception 'versi % bukan versi terbaru untuk %', p_version, k using errcode = '22023';
    end if;
  else
    v := coalesce(p_version, to_char(now() at time zone 'Asia/Jakarta', 'YYYY-MM-DD'));
  end if;
  insert into member.consents (user_id, kind, version) values (uid, k, v)
  on conflict (user_id, kind, version) do update set revoked_at = null, granted_at = now()
    where member.consents.revoked_at is not null;
end $$;
revoke execute on function api.record_consent(text, text, boolean) from public;
grant execute on function api.record_consent(text, text, boolean) to authenticated;
