-- Helper dasar fungsi api (identik di admin/creator/brand, disalin scripts/sync-fn-shared.sh): error berkode & sesi.
-- Konvensi kode error: kepala api/_helpers.sql.
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
