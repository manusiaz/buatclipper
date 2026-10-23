#!/usr/bin/env bash
# Uji bus antar database di stack lokal (scripts/dev-stack.sh) atau server deploy (BUS_DB_PREFIX=deploy): tiap pasangan pengirim→penerima mengirim 2 event lewat
# outbox → relay pg_net → bridge penerima (HMAC) → bus_receive → handler uji. Lulus bila semua event diterapkan berurutan
# dan outbox pengirim menandai terkirim. Handler/tabel uji dibersihkan di akhir.
set -euo pipefail
# Container DB: default stack lokal (scripts/dev-stack.sh); server deploy/deploy.sh: BUS_DB_PREFIX=deploy → core-db, creator-db, brand-db.
if [ "${BUS_DB_PREFIX:-}" = deploy ]; then
  declare -A DB=([admin]=core-db [creator]=creator-db [brand]=brand-db)
else
  declare -A DB=([admin]=supabase_db_clipper-core [creator]=supabase_db_clipper-creator [brand]=supabase_db_clipper-brand)
fi
q() { docker exec -i "${DB[$1]}" psql -U postgres -d postgres -qAt -v ON_ERROR_STOP=1 "${@:2}"; }
PAIRS="creator:admin brand:admin admin:creator admin:brand creator:brand brand:creator"
for t in admin creator brand; do
  q "$t" <<'SQL'
create table if not exists public.bus_e2e_log (src text, v text, at timestamptz default clock_timestamp());
create or replace function bus_in.uji_ping(p jsonb) returns void language sql as
  $$ insert into public.bus_e2e_log (src, v) values (p ->> 'src', p ->> 'v') $$;
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
# Kiriman kembar bersamaan (relay mengulang saat request pertama masih berjalan di DB): yang kedua menunggu lalu dilewati, bukan 500.
ev="[{\"id\":\"$(cat /proc/sys/kernel/random/uuid)\",\"topic\":\"uji.ping\",\"payload\":{\"src\":\"race\",\"v\":\"r\"}}]"
q admin -c "begin; select api.bus_receive('brand', '$ev'); select pg_sleep(2); commit;" >/dev/null &
sleep 0.5
race=$(q admin -c "select api.bus_receive('brand', '$ev') ->> 'skipped'" 2>&1) || true
wait
if [ "$race" = 1 ] && [ "$(q admin -c "select count(*) from public.bus_e2e_log where src = 'race'")" = 1 ]; then echo "✓ kiriman kembar bersamaan dilewati"
else echo "✗ kiriman kembar bersamaan: $race"; fail=1; fi
for t in admin creator brand; do
  q "$t" -c "delete from bus.outbox where topic = 'uji.ping'" -c "delete from bus.inbox where topic = 'uji.ping'" \
         -c "drop function bus_in.uji_ping(jsonb)" -c "drop table public.bus_e2e_log" >/dev/null
done
exit $fail
