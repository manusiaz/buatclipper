SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION tracking.check_account_limit()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
declare
  n int;
  max_n int := coalesce((select (s.value #>> '{}')::int from ops.settings s
                         where s.key = 'public.market.max_accounts_per_platform'), 3);
begin
  -- Hanya yang menambah akun aktif yang dibatasi (insert, disconnected → aktif, pindah user/platform). Perubahan status di antara
  -- verified/token_expired/revoked tidak menambah akun, jadi tetap jalan walau batas config diturunkan (R36-1).
  if tg_op = 'UPDATE' and old.status <> 'disconnected' and old.user_id = new.user_id and old.platform = new.platform then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text || ':' || new.platform::text, 0));
  select count(*) into n from tracking.social_accounts a
   where a.user_id = new.user_id and a.platform = new.platform and a.status <> 'disconnected' and a.id <> new.id;
  if n >= max_n then
    raise exception 'maksimal % akun % per clipper', max_n, new.platform using errcode = '23514';
  end if;
  return new;
end $function$;
