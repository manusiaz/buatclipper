#!/usr/bin/env bash
# Uji bus antar database di stack lokal (scripts/dev-stack.sh): tiap pasangan pengirim→penerima mengirim 2 event lewat
# outbox → relay pg_net → bridge penerima (HMAC) → bus_receive → handler uji. Lulus bila semua event diterapkan berurutan
# dan outbox pengirim menandai terkirim. Handler/tabel uji dibersihkan di akhir.
set -euo pipefail
declare -A DB=([admin]=supabase_db_clipper-core [creator]=supabase_db_clipper-creator [brand]=supabase_db_clipper-brand)
q() { docker exec -i "${DB[$1]}" psql -U postgres -d postgres -qAt -v ON_ERROR_STOP=1 "${@:2}"; }
PAIRS="creator:admin brand:admin admin:creator admin:brand creator:brand brand:creator"
for t in admin creator brand; do
  q "$t" <<'SQL'
create table if not exists public.bus_e2e_log (src text, v text, at timestamptz default clock_timestamp());
create or replace function public.bus_e2e_handler(p jsonb) returns void language sql as
  $$ insert into public.bus_e2e_log (src, v) values (p ->> 'src', p ->> 'v') $$;
insert into bus.handlers (topic, fn) values ('uji.ping', 'public.bus_e2e_handler(jsonb)') on conflict do nothing;
truncate public.bus_e2e_log;
SQL
done
for pr in $PAIRS; do
  f=${pr%%:*}; t=${pr##*:}
  q "$f" -c "select bus.emit('$t', 'uji.ping', jsonb_build_object('src', '$f', 'v', '1')), bus.emit('$t', 'uji.ping', jsonb_build_object('src', '$f', 'v', '2'))" >/dev/null
done
fail=0
for pr in $PAIRS; do
  f=${pr%%:*}; t=${pr##*:}; got=""
  for _ in $(seq 1 40); do
    got=$(q "$t" -c "select string_agg(v, ',' order by at) from public.bus_e2e_log where src = '$f'")
    [ "$got" = "1,2" ] && break; sleep 1
  done
  acked=""
  for _ in $(seq 1 20); do
    acked=$(q "$f" -c "select bool_and(sent_at is not null) from bus.outbox where topic = 'uji.ping' and target = '$t'")
    [ "$acked" = t ] && break; sleep 1
  done
  if [ "$got" = "1,2" ] && [ "$acked" = t ]; then echo "✓ $f → $t"; else
    echo "✗ $f → $t (diterima: '${got}', terkirim: '${acked}', error: $(q "$f" -c "select last_error from bus.outbox where topic = 'uji.ping' and target = '$t' and last_error is not null limit 1"))"; fail=1; fi
done
for t in admin creator brand; do
  q "$t" -c "delete from bus.handlers where topic = 'uji.ping'" -c "delete from bus.outbox where topic = 'uji.ping'" \
         -c "delete from bus.inbox where topic = 'uji.ping'" -c "drop function public.bus_e2e_handler(jsonb)" -c "drop table public.bus_e2e_log" >/dev/null
done
exit $fail
