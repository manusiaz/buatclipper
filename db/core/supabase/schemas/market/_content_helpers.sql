-- Helper konten campaign bersama (sumber tunggal di admin, disalin ke project brand oleh scripts/sync-fn-shared.sh).

-- Angka JSON (number atau string angka) → numeric; selain itu NULL.
create function market.jnum(p jsonb) returns numeric
language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p) = 'number' then (p #>> '{}')::numeric
              when jsonb_typeof(p) = 'string' and (p #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' then (p #>> '{}')::numeric end;
$$;

-- Normalisasi daftar brief (F-B02): hashtag/mention huruf kecil tanpa #/@, link https (tanpa skema → https://), teks di-trim;
-- kosong & duplikat dibuang. Format salah → invalid:<field>.
create function market.norm_list(p jsonb, p_kind text, p_field text) returns text[]
language plpgsql set search_path = '' as $$
declare
  res text[] := '{}';
  x text;
  v text;
begin
  if p is null or jsonb_typeof(p) = 'null' then
    return res;
  end if;
  if jsonb_typeof(p) <> 'array' then
    perform market.fail('invalid:' || p_field, 'harus array');
  end if;
  for x in select jsonb_array_elements_text(p) loop
    v := btrim(x);
    if p_kind = 'hashtag' then
      v := lower(ltrim(v, '#'));
      if v <> '' and v !~ '^[[:lower:][:digit:]_]+$' then
        perform market.fail('invalid:' || p_field, format('hashtag "%s" hanya boleh huruf, angka, _', x));
      end if;
    elsif p_kind = 'mention' then
      v := lower(ltrim(v, '@'));
      if v <> '' and v !~ '^[[:lower:][:digit:]_.]+$' then
        perform market.fail('invalid:' || p_field, format('mention "%s" hanya boleh huruf, angka, _ dan .', x));
      end if;
    elsif p_kind = 'link' and v <> '' then
      if v !~* '^[a-z][a-z0-9+.-]*://' then
        v := 'https://' || v;
      end if;
      if v !~ '^https://\S+$' then
        perform market.fail('invalid:' || p_field, format('link "%s" wajib https', x));
      end if;
    end if;
    if v <> '' and not (v = any (res)) then
      res := res || v;
    end if;
  end loop;
  return res;
end $$;

revoke execute on function market.jnum(jsonb), market.norm_list(jsonb, text, text) from public;
