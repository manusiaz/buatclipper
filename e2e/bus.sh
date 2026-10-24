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
# Sambung OAuth bersamaan dengan penutupan akun (R92-1): menunggu penutupan lalu ditolak, tidak meninggalkan akun/token.
U=11111111-0000-0000-0000-0000000009a2
# profil uji tanpa replika (bus.applying): tidak meninggalkan baris di admin/brand
q creator -c "select set_config('bus.applying', 'on', false)" \
          -c "insert into market.profiles (id, username, display_name) values ('$U', 'uji_r92', 'Uji') on conflict (id) do update set status = 'active'" >/dev/null
q creator -c "begin; update market.profiles set status = 'closed' where id = '$U'; select pg_sleep(2); commit;" >/dev/null &
sleep 0.5
q creator -c "select api.worker_upsert_social_account('$U', 'tiktok', 'uji-r92', '@uji', 1, null, '{}')" >/dev/null 2>&1 || true
wait
if [ "$(q creator -c "select count(*) from tracking.social_accounts where user_id = '$U'")" = 0 ]; then echo "✓ sambung sosmed saat akun ditutup ditolak"
else echo "✗ sambung sosmed saat akun ditutup tersimpan"; fail=1; fi
q creator -c "delete from vault.secrets where id in (select token_ref from tracking.social_accounts where user_id = '$U')" \
          -c "select set_config('bus.applying', 'on', false)" -c "delete from tracking.social_accounts where user_id = '$U'" \
          -c "delete from market.profiles where id = '$U'" >/dev/null
# Ping = watermark lock/settle di admin (CX6/CL11): event dari transaksi yang belum commit tidak boleh diklaim ping — at ping tidak
# melewati awal transaksi yang masih terbuka (created_at event = awal transaksinya), dan ping tetap langsung terkirim (tidak menunggu).
q creator -c "begin; select bus.emit('admin', 'uji.ping', jsonb_build_object('src', 'barrier', 'v', 'b')); select pg_sleep(3); commit;" >/dev/null &
for _ in $(seq 1 50); do
  [ "$(q creator -c "select count(*) from pg_stat_activity where query like '%''barrier''%' and backend_xid is not null and pid <> pg_backend_pid()")" = 1 ] && break; sleep 0.1
done
t0=$(date +%s%N); pid=$(q creator -c "select bus.ping()"); dt=$(( ($(date +%s%N) - t0) / 1000000 ))
wait
ok=$(q creator -c "select (select (payload ->> 'at')::timestamptz from bus.outbox where id = '$pid') <= (select max(created_at) from bus.outbox where payload ->> 'src' = 'barrier')")
if [ "$dt" -lt 1500 ] && [ "$ok" = t ]; then echo "✓ ping tidak mengklaim event yang belum commit, tanpa menunggu (${dt} ms)"
else echo "✗ ping mengklaim event yang belum commit / menunggu (${dt} ms, at ≤ awal transaksi: $ok)"; fail=1; fi
for _ in $(seq 1 20); do [ "$(q admin -c "select count(*) from public.bus_e2e_log where src = 'barrier'")" = 1 ] && break; sleep 1; done
# Restore satu DB (CX2): admin dipulihkan dari backup lama → ada anggota org yang sudah dicabut di brand. Rekonsiliasi dari brand
# (loop sama dengan deploy.sh bus reconcile admin) mengirim ulang state + menghapus baris yang tidak ada di pemilik.
GHOST=00000000-0000-0000-0000-0000000c0a2d
q admin -c "select set_config('bus.applying', 'on', false)" \
        -c "insert into market.org_members (org_id, user_id, role) select org_id, '$GHOST', 'brand_viewer' from market.org_members limit 1 on conflict do nothing" >/dev/null
tables=$(q brand -c "select bus.replica_tables('admin')")
for t in $tables; do q brand -c "select bus.resync('$t', 'admin')" >/dev/null; done
for t in $(echo "$tables" | tac); do q brand -c "select bus.reconcile('$t', 'admin')" >/dev/null; done
want=$(q brand -c "select string_agg(org_id || ':' || user_id, ' ' order by org_id, user_id) from market.org_members")
for _ in $(seq 1 90); do
  got=$(q admin -c "select string_agg(org_id || ':' || user_id, ' ' order by org_id, user_id) from market.org_members")
  [ "$got" = "$want" ] && break; sleep 1
done
if [ "$got" = "$want" ]; then echo "✓ rekonsiliasi: anggota org di admin = brand (yang dicabut terhapus, yang hilang dikirim ulang)"
else echo "✗ rekonsiliasi anggota org: admin '$got' ≠ brand '$want' (error: $(q brand -c "select last_error from bus.outbox where target = 'admin' and sent_at is null and last_error is not null limit 1"))"; fail=1; fi
# O5-1: job bus-reconcile vs replikasi bersamaan — upsert baris yang tidak ada di daftar kunci (dikirim ulang pemilik) sedang
# berjalan saat job mulai → job menunggu kunci, baris tidak dihapus.
E=00000000-0000-0000-0000-0000000005e1; G2=00000000-0000-0000-0000-0000000c0a5e
O=$(q admin -c "select org_id from market.org_members limit 1")
q admin -c "select set_config('bus.applying', 'on', false)" -c "insert into market.org_members (org_id, user_id, role) values ('$O', '$G2', 'brand_viewer') on conflict do nothing" >/dev/null
q admin -c "insert into bus.reconcile_keys (source, tbl, epoch, key) select 'brand', 'market.org_members', '$E', jsonb_build_object('org_id', org_id, 'user_id', user_id) from market.org_members where user_id <> '$G2'" \
        -c "insert into bus.reconcile_runs (source, tbl, epoch, total) values ('brand', 'market.org_members', '$E', 0)" >/dev/null
q admin -c "begin" -c "select bus.apply_row(jsonb_build_object('table', 'market.org_members', 'op', 'upsert', 'key', jsonb_build_object('org_id', '$O', 'user_id', '$G2'), 'row', jsonb_build_object('org_id', '$O', 'user_id', '$G2', 'role', 'brand_viewer')), 'brand')" \
        -c "select pg_sleep(2)" -c "commit" >/dev/null &
for _ in $(seq 1 50); do [ "$(q admin -c "select count(*) from pg_stat_activity where query like '%pg_sleep(2)%' and pid <> pg_backend_pid()")" = 1 ] && break; sleep 0.1; done
q admin -c "select bus.reconcile_apply()" >/dev/null; wait
if [ "$(q admin -c "select exists (select 1 from market.org_members where user_id = '$G2')")" = t ]; then echo "✓ rekonsiliasi tertunda tidak menghapus baris yang sedang dikirim ulang (kunci job ↔ replikasi)"
else echo "✗ job bus-reconcile menghapus baris yang dikirim ulang bersamaan"; fail=1; fi
# O6-1: dua pemanggil job bersamaan — yang menunggu kunci tidak memproses run yang sudah diselesaikan pemanggil pertama
# (daftar kuncinya sudah dihapus → tanpa baca ulang semua anggota org terhapus).
q admin -c "insert into bus.reconcile_keys (source, tbl, epoch, key) select 'brand', 'market.org_members', '$E', jsonb_build_object('org_id', org_id, 'user_id', user_id) from market.org_members on conflict do nothing" \
        -c "insert into bus.reconcile_runs (source, tbl, epoch, total) values ('brand', 'market.org_members', '$E', 0) on conflict do nothing" >/dev/null
before=$(q admin -c "select count(*) from market.org_members")
q admin -c "begin" -c "select bus.reconcile_apply()" -c "select pg_sleep(2)" -c "commit" >/dev/null &
for _ in $(seq 1 50); do [ "$(q admin -c "select count(*) from pg_stat_activity where query like '%pg_sleep(2)%' and pid <> pg_backend_pid()")" = 1 ] && break; sleep 0.1; done
q admin -c "select bus.reconcile_apply()" >/dev/null; wait
after=$(q admin -c "select count(*) from market.org_members")
if [ "$before" = "$after" ]; then echo "✓ dua pemanggil job bersamaan: run yang sudah selesai tidak diproses ulang ($after anggota org tetap)"
else echo "✗ pemanggil kedua memproses run basi: anggota org $before → $after"; fail=1; fi
q admin -c "select set_config('bus.applying', 'on', false)" -c "delete from market.org_members where user_id = '$G2'" \
        -c "delete from bus.reconcile_runs where epoch = '$E'" -c "delete from bus.reconcile_keys where epoch = '$E'" >/dev/null
for t in admin creator brand; do
  q "$t" -c "delete from bus.outbox where topic = 'uji.ping'" -c "delete from bus.inbox where topic = 'uji.ping'" \
         -c "drop function bus_in.uji_ping(jsonb)" -c "drop table public.bus_e2e_log" >/dev/null
done
exit $fail
