#!/usr/bin/env bash
# Deploy self-hosted Clipper Platform: 4 stack Supabase resmi — identity (akun & PII), core (= admin: uang & platform), creator,
# brand — + 5 app Next.js + Caddy (HTTPS otomatis Let's Encrypt). Server per peran (disarankan: data PII identity tidak satu
# mesin dengan data bisnis) atau satu server (`up all`).
# Idempoten: jalankan ulang untuk update (migration baru, fungsi, app).
#
#   Mesin admin (sekali):  deploy/deploy.sh secrets   → secrets.env (lengkap, simpan offline) +
#                          secrets.identity.env / secrets.core.env / secrets.apps.env (hanya yang dibutuhkan server itu)
#   Server A (identity):   salin secrets.identity.env → deploy/secrets.env, isi deploy/config.env, deploy/deploy.sh up identity
#   Server B (core):       salin secrets.core.env     → deploy/secrets.env, isi deploy/config.env, deploy/deploy.sh up core
#   Server creator/brand:  salin secrets.creator.env / secrets.brand.env → deploy/secrets.env, deploy/deploy.sh up creator|brand
#   Server C (app):        salin secrets.apps.env     → deploy/secrets.env, isi deploy/config.env, deploy/deploy.sh up apps
#   Satu server:           deploy/deploy.sh up all   (secret dibuat otomatis bila belum ada)
#   Admin pertama:         deploy/deploy.sh admin email@domain   (di server identity / satu server) → login di admin.{DOMAIN}
#                          dengan kode OTP email, lalu daftarkan authenticator (MFA wajib)
#   Pra-cek sebelum up:    deploy/deploy.sh check [peran]   (compose, secret, DNS, koneksi ke server lain)
#   Backup harian (cron):  15 2 * * * /path/deploy/deploy.sh backup [peran] >> /var/log/clipper-backup.log 2>&1
#                          → deploy/stack/*/backups (dump DB + file Storage, BACKUP_KEEP_DAYS); salin ke luar server
#   deploy/deploy.sh down [peran] · deploy/deploy.sh status
#   Bus antar-DB (stack di server ini): deploy/deploy.sh bus status  → antrean keluar per target, kepala antrean yang macet
#                          (seq, topik, error), ping creator/brand di admin · bus kick → coba kirim ulang sekarang (reset backoff)
#                          · bus skip <stack> <target> <seq> → lewati kepala antrean yang macet permanen (event hilang untuk
#                          penerima; pulihkan state dengan bus.resync) — tunggu attempts ≥ 3: relay lalu mengirim satu per satu,
#                          jadi kepala = event yang gagal — snapshot yang gagal di admin: tombol "Lewati snapshot"
#                          di alert admin.{DOMAIN}, bukan dari sini · bus reconcile <admin|creator|brand> → kirim ulang semua tabel
#                          replika dari stack di server ini ke target + hapus di target baris yang sudah tidak ada di sini
#                          · bus jobs <off|on> → hentikan/jalankan job cron bisnis stack di server ini (restore)
#   Restore SATU DB (core|creator|brand) ke backup lama — runbook (CX2): 1) `deploy.sh down apps` di server app dan `deploy.sh bus
#                          jobs off` di SETIAP server stack (hentikan semua tulisan user, uang & worker) 2) pulihkan dump ke stack itu (pg_restore dari deploy/stack/<stack>/backups), SEGERA
#                          ulangi `deploy.sh bus jobs off` di server itu (dump membawa job cron aktif: lifecycle/release/track-worker
#                          jangan jalan di atas data yang belum lengkap; job bus-* tetap jalan), khusus creator: id snapshot dimajukan
#                          melewati yang sudah dilihat admin: ambil `select max(id) from tracking.view_snapshots` di core-db, lalu di creator-db `alter table
#                          tracking.view_snapshots alter column id restart with <max+1>` — lalu `deploy.sh up <stack>`
#                          3) di SETIAP server stack lain: `deploy.sh bus reconcile <nama bus stack yang dipulihkan>` (state yang
#                          hilang dikirim ulang, baris yang dicabut sesudah backup — mis. anggota org — dihapus) 4) di server stack
#                          yang dipulihkan: `deploy.sh bus reconcile <tiap stack lain>` (stack itu sekarang sumber kebenaran datanya
#                          sendiri) 5) `deploy.sh bus status` di semua server sampai antrean kosong; alert admin bus.rejected_payload
#                          berisi baris yang TIDAK diubah otomatis dan perlu keputusan manual: reconcile_delete (baris tidak boleh
#                          dihapus: append-only/dirujuk catatan uang, mis. snapshot yang hilang dari creator), orphan (induk hilang
#                          bersama DB yang dipulihkan, mis. submisi yang claim-nya hilang dari admin), reconcile_incomplete (ulangi
#                          reconcile); kepala antrean yang macet foreign key (event biasa yang induknya ikut hilang, sudah antre sebelum
#                          resync) → `deploy.sh bus skip` (barisnya dikirim ulang resync di belakangnya lalu dilaporkan orphan);
#                          perintah/event non-replika di jendela backup hilang: cek audit 6) `deploy.sh bus jobs on` di SETIAP server
#                          stack, lalu `deploy.sh up apps`.
#
# DNS A: auth.{DOMAIN} → server identity, api.{DOMAIN} → server core (admin), creator-api.{DOMAIN} → server creator,
# brand-api.{DOMAIN} → server brand, {DOMAIN} + accounts./app./brand./admin. → server app. Satu server: semua ke IP yang sama.
# Syarat tiap server: Docker Engine + compose ≥ 2.24.4 (tag !override), git, port 80/443 terbuka. deploy/secrets.env
# disimpan terpisah dari backup (tanpa kunci PII/Vault dump tidak terbaca utuh). Studio (dashboard DB) tidak publik:
# ssh -L 8001:127.0.0.1:8001 server-identity (core: 8002, creator: 8003, brand: 8004) → http://localhost:800x (user supabase,
# password {IDENTITY|CORE|CREATOR|BRAND}_DASHBOARD_PASSWORD di secrets.env).
set -euo pipefail
cd "$(dirname "$0")"
DEPLOY=$PWD ROOT=$(cd .. && pwd)
# supabase/supabase docker/ (compose self-hosted resmi) yang diuji dengan deploy ini.
SUPABASE_REF=${SUPABASE_REF:-d897e1462ad33ee9c7daba8cfee8f14e303c0cf5}

CMD=${1:-} ROLE=${2:-all}
[ "$CMD" = admin ] && { ADMIN_EMAIL=${2:-}; ROLE=identity; }
[ "$CMD" = bus ] && { BUS_OP=${2:-status}; BUS_ARGS=("${@:3}"); ROLE=all; }
ALL_STACKS="identity core creator brand"
case "$ROLE" in all | identity | core | creator | brand | apps) ;; *) echo "peran tidak dikenal: $ROLE (all|identity|core|creator|brand|apps)"; exit 1 ;; esac
case "$ROLE" in all) STACKS=$ALL_STACKS SITES="apps $ALL_STACKS" ;; apps) STACKS="" SITES=apps ;; *) STACKS=$ROLE SITES=$ROLE ;; esac

load_config() {
  [ -f config.env ] || { echo "deploy/config.env belum ada: cp deploy/config.env.example deploy/config.env lalu isi"; exit 1; }
  chmod 600 config.env   # berisi kredensial SMTP/OAuth
  set -a; . ./config.env; set +a
  SCHEME=${SCHEME:-https}
  [[ "${DOMAIN:-}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || { echo "DOMAIN tidak valid: '${DOMAIN:-}'"; exit 1; }
  [[ "$SCHEME" =~ ^https?$ ]] || { echo "SCHEME harus https atau http"; exit 1; }
  if [[ $CMD =~ ^(up|check)$ ]] && [[ " $STACKS " == *" identity "* ]]; then
    # GoTrue gagal start (crash loop) bila port SMTP kosong → hentikan sebelum container dibuat.
    [[ "${SMTP_PORT:-}" =~ ^[0-9]+$ ]] || { echo "SMTP_PORT (config.env) wajib angka, mis. 465"; exit 1; }
    [ -n "${SMTP_PASS:-}" ] || echo "PERINGATAN: SMTP_PASS kosong — email kode login (OTP) tidak akan terkirim"
    [ -n "${RESEND_API_KEY:-}" ] || echo "PERINGATAN: RESEND_API_KEY kosong — email notifikasi platform tidak akan terkirim"
  fi
  WEB="$SCHEME://$DOMAIN" ACC="$SCHEME://accounts.$DOMAIN" APP="$SCHEME://app.$DOMAIN" BRAND="$SCHEME://brand.$DOMAIN"
  ADMIN="$SCHEME://admin.$DOMAIN" AUTH="$SCHEME://auth.$DOMAIN" API="$SCHEME://api.$DOMAIN"
  CREATOR_API="$SCHEME://creator-api.$DOMAIN" BRAND_API="$SCHEME://brand-api.$DOMAIN"
}
# Host publik API tiap stack (Caddy deploy/caddy/<stack>.caddy) dan nama stack di bus (core = admin).
stack_host() { case $1 in identity) echo "auth.$DOMAIN" ;; core) echo "api.$DOMAIN" ;; *) echo "$1-api.$DOMAIN" ;; esac; }
bus_name() { [ "$1" = core ] && echo admin || echo "$1"; }

node_run() { docker run --rm -u "$(id -u):$(id -g)" -v "$DEPLOY":/w -v "$ROOT/db":/db:ro -w /w node:22-alpine node "$@"; }

# Kunci per peran (least privilege): server identity tidak memegang kunci core, server core tidak memegang kunci PII /
# private key token user, server app hanya kunci publik (anon key, VAPID publik).
role_keys() {
  case "$1" in
    identity) echo '^(IDENTITY_[A-Z0-9_]+|BRIDGE_SECRET_[A-Z_]+|PII_[A-Z_]+|VAPID_PUBLIC_KEY|VAPID_PRIVATE_KEY|DISBURSE_CALLBACK_TOKEN)=' ;;
    # Secret bus: hanya pasangan yang melibatkan stack ini (pengirim memegang secret ke tiap target, penerima dari tiap pengirim).
    core) echo '^(CORE_[A-Z0-9_]+|BRIDGE_SECRET_[A-Z_]+|UNSUBSCRIBE_SECRET|BUS_ADMIN_TO_[A-Z]+|BUS_[A-Z]+_TO_ADMIN)=' ;;
    creator) echo '^(CREATOR_[A-Z0-9_]+|BUS_CREATOR_TO_[A-Z]+|BUS_[A-Z]+_TO_CREATOR)=' ;;
    brand) echo '^(BRAND_[A-Z0-9_]+|BUS_BRAND_TO_[A-Z]+|BUS_[A-Z]+_TO_BRAND)=' ;;
    apps) echo '^(IDENTITY_ANON_KEY|CORE_ANON_KEY|BRAND_ANON_KEY|CREATOR_ANON_KEY|VAPID_PUBLIC_KEY)=' ;;
  esac
}
make_secrets() {
  node_run keys.mjs secrets.env   # baru → dibuat; lama → hanya kunci yang belum ada ditambahkan (stack/bus baru)
  local r
  for r in $ALL_STACKS apps; do (umask 077 && grep -E "$(role_keys "$r")" secrets.env > "secrets.$r.env"); done
}
# secrets.env = KEY=value literal (JSON/JWT), dibaca tanpa evaluasi shell.
load_secrets() {
  if [ "$ROLE" = all ]; then
    make_secrets
  elif [ ! -f secrets.env ]; then
    echo "deploy/secrets.env belum ada: jalankan 'deploy.sh secrets' di mesin admin lalu salin secrets.$ROLE.env ke sini sebagai deploy/secrets.env"; exit 1
  fi
  chmod 600 secrets.env
  while IFS='=' read -r k v; do [ -n "$k" ] && export "$k=$v"; done < secrets.env
  local r need stack_keys="POSTGRES_PASSWORD JWT_SECRET ANON_KEY SERVICE_ROLE_KEY JWT_JWKS SECRET_KEY_BASE VAULT_ENC_KEY
    PG_META_CRYPTO_KEY DASHBOARD_PASSWORD S3_PROTOCOL_ACCESS_KEY_ID S3_PROTOCOL_ACCESS_KEY_SECRET"
  local bus_in bus_out
  for r in $ALL_STACKS apps; do
    [ "$ROLE" = all ] || [ "$ROLE" = "$r" ] || continue
    bus_in= bus_out=
    if [[ $r =~ ^(core|creator|brand)$ ]]; then
      local me=$(bus_name "$r") o
      for o in admin creator brand; do [ "$o" = "$me" ] || { bus_in+=" BUS_${o^^}_TO_${me^^}"; bus_out+=" BUS_${me^^}_TO_${o^^}"; }; done
    fi
    case $r in
      identity) need="$(printf 'IDENTITY_%s ' $stack_keys) IDENTITY_JWT_KEYS BRIDGE_SECRET_CORE_TO_IDENTITY BRIDGE_SECRET_IDENTITY_TO_CORE
                      PII_HMAC_KEY PII_ENC_KEYS PII_ENC_KEY_VERSION VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY DISBURSE_CALLBACK_TOKEN" ;;
      core) need="$(printf 'CORE_%s ' $stack_keys) BRIDGE_SECRET_CORE_TO_IDENTITY BRIDGE_SECRET_IDENTITY_TO_CORE UNSUBSCRIBE_SECRET$bus_in$bus_out" ;;
      creator | brand) need="$(printf "${r^^}_%s " $stack_keys)$bus_in$bus_out" ;;
      apps) need="IDENTITY_ANON_KEY CORE_ANON_KEY BRAND_ANON_KEY CREATOR_ANON_KEY VAPID_PUBLIC_KEY" ;;
    esac
    for k in $need; do [ -n "${!k:-}" ] || { echo "secrets.env kurang $k untuk peran $r"; exit 1; }; done
  done
  if [[ $CMD =~ ^(up|check)$ ]] && [ "$ROLE" != all ] && grep -qvE "$(role_keys "$ROLE")" secrets.env; then
    echo "PERINGATAN: secrets.env berisi kunci peran lain — di server $ROLE pakai secrets.$ROLE.env saja"
  fi
}

# PEER_HOSTS (config.env) "host=ip ..." → alamat host publik server lain lewat jaringan privat; kosong = DNS publik.
peer_ip() { local x; for x in ${PEER_HOSTS:-}; do [ "${x%%=*}" = "$1" ] && { echo "${x#*=}"; return; }; done; return 0; }
# Host publik → tujuan extra_hosts container: dilayani Caddy server ini, server lain (PEER_HOSTS), atau DNS (kosong).
host_target() {
  if [[ " $(served_hosts) " == *" $1 "* ]]; then echo "${CADDY_BIND:-host-gateway}"; else peer_ip "$1"; fi
}
served_hosts() {
  local s
  for s in $SITES; do
    case $s in
      apps) echo "$DOMAIN accounts.$DOMAIN app.$DOMAIN brand.$DOMAIN admin.$DOMAIN" ;;
      *) stack_host "$s" ;;
    esac
  done | tr '\n' ' '
}
extra_hosts_yaml() { # service... — blok compose extra_hosts untuk host API stack (fungsi, Auth, db/pg_net bus, app server-side)
  local svc h t lines=
  for h in $(for p in $ALL_STACKS; do stack_host "$p"; done); do t=$(host_target "$h"); [ -n "$t" ] && lines+="      - $h:$t"$'\n'; done
  echo "services:"
  for svc in "$@"; do
    if [ -n "$lines" ]; then printf '  %s:\n    extra_hosts:\n%s' "$svc" "$lines"; else printf '  %s: {}\n' "$svc"; fi
  done
}

setenv() { # file key value — ganti/tambah baris tanpa menafsirkan isi value; file pengganti 0600 sejak dibuat
  (umask 077 && K="$2" V="$3" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
    index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next } { print }
    END { if (!done) print k "=" v }' "$1" > "$1.tmp") && mv "$1.tmp" "$1"
}

fetch_supabase() {
  local src=stack/.supabase
  if [ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" != "$SUPABASE_REF" ]; then
    rm -rf "$src" && mkdir -p "$src"
    git -C "$src" init -q && git -C "$src" remote add origin https://github.com/supabase/supabase.git
    git -C "$src" sparse-checkout set docker
    git -C "$src" fetch -q --depth 1 --filter=blob:none origin "$SUPABASE_REF"
    git -C "$src" checkout -q FETCH_HEAD
  fi
}

# Satu stack: salin compose resmi (volumes data lama tidak ditimpa), override, .env, fungsi.
prepare_stack() { # identity|core|creator|brand
  local p=$1 P=${1^^} dir=stack/$1
  mkdir -p "$dir"
  copy_tree stack/.supabase/docker "$dir" --exclude=./volumes/db/data --exclude=./volumes/storage --exclude=./volumes/functions
  mkdir -p "$dir/volumes/functions" "$dir/volumes/storage"
  cp supabase/common.yml "$dir/clipper.common.yml"; cp "supabase/$p.yml" "$dir/clipper.$p.yml"
  local e=$dir/.env pub line
  [ -f "$e" ] || (umask 077 && cp "$dir/.env.example" "$e")
  # SUPABASE_REF dinaikkan → variabel baru compose resmi ikut masuk (nilai lama tidak disentuh).
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Z0-9_]+)= ]] && ! grep -q "^${BASH_REMATCH[1]}=" "$e"; then printf '%s\n' "$line" >> "$e"; fi
  done < "$dir/.env.example"
  pub="$SCHEME://$(stack_host "$p")"
  # EXTRA_COMPOSE_FILES (config.env, pisah ':'): override tambahan, mis. docker-compose.s3.yml resmi untuk storage S3.
  extra_hosts_yaml auth functions db > "$dir/clipper.hosts.yml"
  setenv "$e" COMPOSE_FILE "docker-compose.yml:clipper.common.yml:clipper.$p.yml:clipper.hosts.yml${EXTRA_COMPOSE_FILES:+:$EXTRA_COMPOSE_FILES}"
  setenv "$e" COMPOSE_PROJECT_NAME "clipper-$p"
  setenv "$e" STACK "$p"
  for k in POSTGRES_PASSWORD JWT_SECRET ANON_KEY SERVICE_ROLE_KEY JWT_JWKS SECRET_KEY_BASE VAULT_ENC_KEY PG_META_CRYPTO_KEY \
           DASHBOARD_PASSWORD S3_PROTOCOL_ACCESS_KEY_ID S3_PROTOCOL_ACCESS_KEY_SECRET; do
    local var="${P}_$k"; setenv "$e" "$k" "${!var}"
  done
  setenv "$e" SUPABASE_PUBLIC_URL "$pub"
  setenv "$e" API_EXTERNAL_URL "$pub/auth/v1"
  setenv "$e" JWT_EXPIRY 600
  setenv "$e" PGRST_DB_SCHEMAS api
  setenv "$e" PGRST_DB_EXTRA_SEARCH_PATH extensions
  setenv "$e" FUNCTIONS_VERIFY_JWT false   # tiap fungsi memverifikasi sendiri (config.toml verify_jwt = false)
  setenv "$e" ENABLE_PHONE_SIGNUP false; setenv "$e" ENABLE_PHONE_AUTOCONFIRM false; setenv "$e" ENABLE_ANONYMOUS_USERS false
  setenv "$e" STUDIO_DEFAULT_PROJECT "$p"
  setenv "$e" POOLER_TENANT_ID "clipper-$p"
  setenv "$e" APP_ORIGINS "$ACC,$APP,$BRAND,$ADMIN"
  setenv "$e" IDENTITY_PUBLIC_URL "$AUTH"; setenv "$e" CORE_PUBLIC_URL "$API"
  if [[ $p =~ ^(identity|core)$ ]]; then  # bridge identity ↔ admin; file secret creator/brand tidak memuatnya (role_keys)
    setenv "$e" BRIDGE_SECRET_CORE_TO_IDENTITY "$BRIDGE_SECRET_CORE_TO_IDENTITY"
    setenv "$e" BRIDGE_SECRET_IDENTITY_TO_CORE "$BRIDGE_SECRET_IDENTITY_TO_CORE"
  fi
  # Penerima bus (fungsi bridge): secret dari tiap pengirim → BUS_SECRET_FROM_<PENGIRIM> (deploy/supabase/<stack>.yml).
  if [[ $p =~ ^(core|creator|brand)$ ]]; then
    local me=$(bus_name "$p") o v
    for o in admin creator brand; do
      [ "$o" = "$me" ] && continue
      v="BUS_${o^^}_TO_${me^^}"; setenv "$e" "BUS_SECRET_FROM_${o^^}" "${!v}"
    done
  fi
  if [ "$p" = identity ]; then
    setenv "$e" GW_PORT 8001; setenv "$e" DB_PORT 5433
    setenv "$e" JWT_KEYS "$IDENTITY_JWT_KEYS"
    setenv "$e" STORAGE_FILE_SIZE_LIMIT 52428800
    setenv "$e" SITE_URL "$ACC"
    setenv "$e" ADDITIONAL_REDIRECT_URLS "$ACC/auth/callback,$ACC/auth/confirm,$APP/auth/callback"
    setenv "$e" DISABLE_SIGNUP false; setenv "$e" ENABLE_EMAIL_SIGNUP true
    setenv "$e" ENABLE_EMAIL_AUTOCONFIRM true   # login OTP: email terverifikasi saat kode dipakai
    for k in SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_ADMIN_EMAIL SMTP_SENDER_NAME; do setenv "$e" "$k" "${!k:-}"; done
    setenv "$e" AUTH_EMAIL_RATE_LIMIT "${AUTH_EMAIL_RATE_LIMIT:-1000}"
    # Login Google (packages/auth signInWithOAuth): client OAuth Google di identity, terpisah dari koneksi YouTube core.
    setenv "$e" GOOGLE_LOGIN_ENABLED "$([ -n "${GOOGLE_LOGIN_CLIENT_ID:-}" ] && echo true || echo false)"
    setenv "$e" GOOGLE_LOGIN_CLIENT_ID "${GOOGLE_LOGIN_CLIENT_ID:-}"; setenv "$e" GOOGLE_LOGIN_SECRET "${GOOGLE_LOGIN_SECRET:-}"
    # CAPTCHA Turnstile diverifikasi Auth identity (widget saja tidak menahan panggilan langsung ke /auth/v1/otp).
    setenv "$e" CAPTCHA_ENABLED "$([ -n "${TURNSTILE_SECRET_KEY:-}" ] && echo true || echo false)"
    setenv "$e" TURNSTILE_SECRET_KEY "${TURNSTILE_SECRET_KEY:-}"
    for k in PII_HMAC_KEY PII_ENC_KEYS PII_ENC_KEY_VERSION VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY; do setenv "$e" "$k" "${!k}"; done
    # Xendit menandatangani callback dengan "Callback Verification Token" miliknya (header x-callback-token) → pakai itu.
    setenv "$e" DISBURSE_CALLBACK_TOKEN "${XENDIT_CALLBACK_TOKEN:-$DISBURSE_CALLBACK_TOKEN}"
    for k in RESEND_API_KEY EMAIL_FROM XENDIT_SECRET_KEY EXPO_ACCESS_TOKEN APNS_KEY_ID APNS_TEAM_ID APNS_BUNDLE_ID APNS_ENV; do
      setenv "$e" "$k" "${!k:-}"
    done
    # Kunci .p8 multi-baris → satu baris "\n" literal (.env compose satu baris per kunci); _shared/apns.ts membaliknya.
    # Lewat ekspansi parameter + setenv (ENVIRON awk), nilai tidak pernah jadi argumen proses.
    local apns_key=${APNS_PRIVATE_KEY:-}; apns_key=${apns_key//$'\r'/}
    setenv "$e" APNS_PRIVATE_KEY "${apns_key//$'\n'/\\n}"
    setenv "$e" DISBURSE_PROVIDER "${DISBURSE_PROVIDER:-mock}"
    setenv "$e" VAPID_SUBJECT "mailto:${SMTP_ADMIN_EMAIL:-admin@$DOMAIN}"
    setenv "$e" APP_URL "$APP"; setenv "$e" BRAND_URL "$BRAND"; setenv "$e" ACCOUNTS_URL "$ACC"; setenv "$e" ADMIN_URL "$ADMIN"
  elif [ "$p" != core ]; then   # creator | brand: tanpa login sendiri, percaya token identity (JWKS bersama)
    [ "$p" = creator ] && { setenv "$e" GW_PORT 8003; setenv "$e" DB_PORT 5435; setenv "$e" SITE_URL "$APP"; }
    [ "$p" = brand ] && { setenv "$e" GW_PORT 8004; setenv "$e" DB_PORT 5436; setenv "$e" SITE_URL "$BRAND"; }
    setenv "$e" STORAGE_FILE_SIZE_LIMIT 524288000   # brand: campaign-assets 500 MiB
    setenv "$e" DISABLE_SIGNUP true; setenv "$e" ENABLE_EMAIL_SIGNUP false
    setenv "$e" IDENTITY_ISSUER "$AUTH/auth/v1"
    if [ "$p" = creator ]; then   # OAuth sosmed: Edge Function social / track-worker / refresh-tokens
      setenv "$e" SOCIAL_REDIRECT_ALLOWLIST \
        "$(for x in tiktok instagram youtube threads facebook x; do printf '%s/api/oauth/%s/callback,' "$APP" "$x"; done | sed 's/,$//')"
      for k in TIKTOK_CLIENT_KEY TIKTOK_CLIENT_SECRET META_APP_ID META_APP_SECRET GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET YOUTUBE_API_KEY \
               THREADS_APP_ID THREADS_APP_SECRET FACEBOOK_APP_ID FACEBOOK_APP_SECRET X_CLIENT_ID X_CLIENT_SECRET; do
        setenv "$e" "$k" "${!k:-}"
      done
    fi
  else
    setenv "$e" GW_PORT 8002; setenv "$e" DB_PORT 5434
    setenv "$e" STORAGE_FILE_SIZE_LIMIT 524288000
    setenv "$e" SITE_URL "$APP"
    setenv "$e" DISABLE_SIGNUP true; setenv "$e" ENABLE_EMAIL_SIGNUP false
    setenv "$e" IDENTITY_ISSUER "$AUTH/auth/v1"
    setenv "$e" UNSUBSCRIBE_SECRET "$UNSUBSCRIBE_SECRET"
  fi
  chmod 600 "$e"

  # Fungsi: router main resmi + fungsi platform; import map gabungan (main memakai satu deno.jsonc untuk semua worker).
  local fn=$dir/volumes/functions src=$ROOT/db/$p/supabase/functions
  find "$fn" -mindepth 1 -maxdepth 1 ! -name main -exec rm -rf {} +
  copy_tree stack/.supabase/docker/volumes/functions/main "$fn/main"
  copy_tree "$src" "$fn" --exclude='*_test.ts' --exclude=./deno.json --exclude=./deno.lock --exclude=./import_map.json
  node_run -e '
    const fs = require("fs");
    const [up, ours, out] = process.argv.slice(1);
    const strip = (s) => s.replace(/^\s*\/\/.*$/gm, "");
    const a = JSON.parse(strip(fs.readFileSync(up, "utf8")));
    const b = JSON.parse(fs.readFileSync(ours, "utf8"));
    fs.writeFileSync(out, JSON.stringify({ ...a, imports: { ...a.imports, ...b.imports } }, null, 2) + "\n");
  ' "stack/.supabase/docker/volumes/functions/deno.jsonc" "/db/$p/supabase/functions/import_map.json" "$fn/deno.jsonc"
}

compose() { (cd "stack/$1" && docker compose "${@:2}"); }
wait_healthy() { # stack service... — Auth & Storage harus selesai migrasi schema-nya sebelum migration platform (FK ke auth/storage)
  local s
  for s in "${@:2}"; do
    for _ in $(seq 1 120); do
      [ "$(docker inspect -f '{{.State.Health.Status}}' "$1-$s" 2>/dev/null)" = healthy ] && continue 2
      sleep 2
    done
    echo "$1-$s tidak sehat"; docker logs --tail 30 "$1-$s"; exit 1
  done
}
copy_tree() { # src dst [--exclude=pola ...] — tar (ada di semua server), tanpa menghapus isi dst yang tidak ada di src
  mkdir -p "$2" && (cd "$1" && tar cf - "${@:3}" .) | (cd "$2" && tar xf -)
}
psql_db() { # stack [psql args...] — sebagai postgres (pemilik objek, sama dengan supabase db push)
  docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "$1-db" psql -h localhost -U postgres -d postgres -X -q \
    -v ON_ERROR_STOP=1 "${@:2}"
}

# Migration db/<p>/supabase/migrations berurutan, satu transaksi per file; dicatat di supabase_migrations.schema_migrations
# (format CLI, jadi `supabase db push --db-url` tetap konsisten bila dipakai nanti).
migrate() {
  local p=$1 f v n
  # Vault lebih dulu: job pg_cron dari migration langsung jalan dan butuh URL + key ini. Variabel psql (:'x') hanya
  # diinterpolasi dari stdin/-f, bukan -c.
  local svc="${p^^}_SERVICE_ROLE_KEY"
  psql_db "$p" -tA -o /dev/null -v url="http://kong:8000" -v key="${!svc}" -v url_name="${p}_url" -v key_name="${p}_secret_key" <<'SQL'
select vault.update_secret(id, :'url') from vault.secrets where name = :'url_name';
select vault.create_secret(:'url', :'url_name') where not exists (select 1 from vault.secrets where name = :'url_name');
select vault.update_secret(id, :'key') from vault.secrets where name = :'key_name';
select vault.create_secret(:'key', :'key_name') where not exists (select 1 from vault.secrets where name = :'key_name');
SQL
  psql_db "$p" -c "create schema if not exists supabase_migrations;
    create table if not exists supabase_migrations.schema_migrations (version text not null primary key, statements text[], name text)"
  local applied backup=
  applied=$(psql_db "$p" -tA -c "select version from supabase_migrations.schema_migrations")
  for f in "$ROOT/db/$p/supabase/migrations/"*.sql; do
    v=$(basename "$f" .sql); n=${v#*_}; v=${v%%_*}
    grep -qx "$v" <<< "$applied" && continue
    if [ -z "$backup" ] && [ -n "$applied" ]; then   # DB sudah berisi + ada migration baru → backup dulu (pg_restore)
      backup=stack/$p/backups/pre-$v-$(date +%Y%m%d%H%M%S).dump
      mkdir -p "stack/$p/backups"
      (umask 077 && docker exec "$p-db" pg_dump -h localhost -U supabase_admin -d postgres -Fc > "$backup")
      echo "  $p: backup $backup"
    fi
    echo "  $p: migration $v $n"
    { cat "$f"; printf "\ninsert into supabase_migrations.schema_migrations (version, name) values ('%s', '%s');\n" "$v" "$n"; } \
      | psql_db "$p" -1 -o /dev/null   # hasil select (mis. cron.schedule) tidak dicetak; error tetap ke stderr
  done
  psql_db "$p" -o /dev/null < "$ROOT/db/$p/supabase/seed.sql"
  node_run buckets.mjs "/db/$p/supabase/config.toml" | psql_db "$p" -o /dev/null
  if [ "$p" != identity ]; then
    psql_db "$p" -v iss="$AUTH/auth/v1" <<'SQL'
update ops.settings set value = to_jsonb(:'iss'::text) where key = 'auth.identity_issuer';
SQL
    # Bus pengirim (Vault): URL publik bridge tiap target + secret pasangan; relay pg_cron/pg_net dari container db (extra_hosts).
    local me=$(bus_name "$p") t tp sec
    for t in admin creator brand; do
      [ "$t" = "$me" ] && continue
      tp=$t; [ "$t" = admin ] && tp=core
      sec="BUS_${me^^}_TO_${t^^}"
      psql_db "$p" -tA -o /dev/null -v url="$SCHEME://$(stack_host "$tp")" -v key="${!sec}" -v url_name="bus_url_$t" -v key_name="bus_secret_$t" <<'SQL'
select vault.update_secret(id, :'url') from vault.secrets where name = :'url_name';
select vault.create_secret(:'url', :'url_name') where not exists (select 1 from vault.secrets where name = :'url_name');
select vault.update_secret(id, :'key') from vault.secrets where name = :'key_name';
select vault.create_secret(:'key', :'key_name') where not exists (select 1 from vault.secrets where name = :'key_name');
SQL
    done
  else
    psql_db identity -v web="https://$DOMAIN" <<'SQL'   # legal_versions.url wajib https (CHECK)
update member.legal_versions set url = :'web' || substr(url, length('https://clipper.localhost') + 1)
 where url like 'https://clipper.localhost/%';
SQL
  fi
}

apps_env() {
  {
    echo "APP_IMAGE=${APP_IMAGE:-}"
    echo "NEXT_PUBLIC_IDENTITY_URL=$AUTH"; echo "NEXT_PUBLIC_IDENTITY_PUBLISHABLE_KEY=$IDENTITY_ANON_KEY"
    echo "NEXT_PUBLIC_CORE_URL=$API"; echo "NEXT_PUBLIC_CORE_PUBLISHABLE_KEY=$CORE_ANON_KEY"
    echo "NEXT_PUBLIC_BRAND_DB_URL=$BRAND_API"; echo "NEXT_PUBLIC_BRAND_DB_PUBLISHABLE_KEY=$BRAND_ANON_KEY"
    echo "NEXT_PUBLIC_CREATOR_DB_URL=$CREATOR_API"; echo "NEXT_PUBLIC_CREATOR_DB_PUBLISHABLE_KEY=$CREATOR_ANON_KEY"
    echo "NEXT_PUBLIC_COOKIE_DOMAIN=.$DOMAIN"
    echo "NEXT_PUBLIC_WEB_URL=$WEB"; echo "NEXT_PUBLIC_ACCOUNTS_URL=$ACC"; echo "NEXT_PUBLIC_APP_URL=$APP"
    echo "NEXT_PUBLIC_BRAND_URL=$BRAND"; echo "NEXT_PUBLIC_ADMIN_URL=$ADMIN"
    echo "NEXT_PUBLIC_VAPID_PUBLIC_KEY=$VAPID_PUBLIC_KEY"; echo "NEXT_PUBLIC_TURNSTILE_SITE_KEY=${NEXT_PUBLIC_TURNSTILE_SITE_KEY:-}"
    # App Android (TWA / native) & iOS native: dibaca saat request oleh app.{domain}/.well-known/assetlinks.json dan
    # apple-app-site-association (bukan secret, tanpa rebuild). Team/bundle iOS default = nilai APNs.
    echo "ANDROID_APP_PACKAGE=${ANDROID_APP_PACKAGE:-}"; echo "ANDROID_CERT_SHA256=${ANDROID_CERT_SHA256:-}"
    echo "APPLE_TEAM_ID=${APPLE_TEAM_ID:-${APNS_TEAM_ID:-}}"; echo "IOS_BUNDLE_ID=${IOS_BUNDLE_ID:-${APNS_BUNDLE_ID:-}}"
  } > apps.env
}
apps() { docker compose -f apps.yml -f .generated/apps.hosts.yml --env-file apps.env -p clipper-apps "$@"; }

# Caddy server ini: hanya situs peran server (base + apps/identity/core), alias network = host yang dilayani di sini
# supaya fetch server-side app ke host lokal tidak keluar ke internet.
caddy_up() {
  local bind=${CADDY_BIND:+$CADDY_BIND:} h s
  mkdir -p .generated
  { cat caddy/base.caddy; for s in $SITES; do echo; cat "caddy/$s.caddy"; done; } > .generated/Caddyfile
  {
    echo "name: clipper-caddy-$ROLE"
    echo "services:"
    echo "  caddy:"
    echo "    image: caddy:2.10.2"
    echo "    restart: unless-stopped"
    echo "    ports: [\"${bind}80:80\", \"${bind}443:443\", \"${bind}443:443/udp\"]"
    echo "    environment: [DOMAIN, SCHEME, ACME_EMAIL]   # dari config.env (diekspor)"
    echo "    volumes:"
    echo "      - $DEPLOY/.generated/Caddyfile:/etc/caddy/Caddyfile:ro"
    [[ " $SITES " == *" identity "* ]] && echo "      - $ROOT/db/identity/supabase/templates:/srv/email:ro"
    echo "      - caddy-data:/data"
    echo "      - caddy-config:/config"
    echo "    networks:"
    echo "      clipper:"
    echo "        aliases:"
    for h in $(served_hosts); do echo "          - $h"; done
    echo "volumes: {caddy-data: {}, caddy-config: {}}"
    echo "networks: {clipper: {external: true, name: clipper}}"
  } > .generated/caddy.yml
  docker compose -f .generated/caddy.yml up -d --remove-orphans
  docker compose -f .generated/caddy.yml restart caddy >/dev/null   # muat ulang Caddyfile
}

case "$CMD" in
  secrets)
    make_secrets
    echo "secrets.env (lengkap, simpan offline) + secrets.{identity,core,creator,brand,apps}.env dibuat"
    ;;
  up)
    load_config
    load_secrets
    docker network inspect clipper >/dev/null 2>&1 || docker network create clipper >/dev/null
    [ -n "$STACKS" ] && fetch_supabase
    for p in $STACKS; do
      prepare_stack "$p"
      echo "stack $p: start"
      # PostgREST baru sehat setelah schema api ada (migration) → --wait hanya setelah migrate.
      compose "$p" up -d --remove-orphans
      wait_healthy "$p" db auth storage
      migrate "$p"
      compose "$p" restart functions rest >/dev/null   # muat ulang fungsi, env, dan schema cache
      compose "$p" up -d --wait
    done
    if [[ " $SITES " == *" apps "* ]]; then
      apps_env
      mkdir -p .generated && extra_hosts_yaml web accounts clipper brand admin > .generated/apps.hosts.yml
      if [ -n "${APP_IMAGE:-}" ]; then   # image dari CI: tarik bila belum ada, jangan dibangun ulang dari Dockerfile
        docker image inspect "$APP_IMAGE" >/dev/null 2>&1 || docker pull "$APP_IMAGE"
      else
        echo "app: build"; apps build
      fi
      apps up -d --no-build --remove-orphans
    fi
    caddy_up
    # Event bus yang gagal selama deploy (stack/Caddy tujuan belum hidup) tertahan backoff s.d. 1 jam → kirim ulang sekarang;
    # hitungan gagal dinolkan supaya kegagalan akibat deploy tidak terbaca bus.stuck (alert) dan tidak memperpanjang backoff.
    for p in $STACKS; do
      [ "$p" = identity ] || psql_db "$p" -c "update bus.outbox set next_at = now(), attempts = 0 where sent_at is null and request_id is null and attempts > 0"
    done
    echo "siap ($ROLE): $(served_hosts)"
    ;;
  down)
    load_config
    [ -f .generated/caddy.yml ] && docker compose -f .generated/caddy.yml down
    [[ " $SITES " == *" apps "* ]] && [ -f .generated/apps.hosts.yml ] && apps down
    for p in $STACKS; do [ -d "stack/$p" ] && compose "$p" down; done
    true
    ;;
  status)
    for p in $ALL_STACKS; do [ -d "stack/$p" ] && compose "$p" ps --format 'table {{.Name}}\t{{.Status}}'; done
    [ -f .generated/apps.hosts.yml ] && apps ps --format 'table {{.Name}}\t{{.Status}}'
    [ -f .generated/caddy.yml ] && docker compose -f .generated/caddy.yml ps --format 'table {{.Name}}\t{{.Status}}'
    true
    ;;
  check)
    load_config
    if [ -f secrets.env ] || [ "$ROLE" != all ]; then load_secrets; else echo "secrets.env belum ada — dibuat otomatis oleh up all"; fi
    v=$(docker compose version --short 2>/dev/null) || { echo "docker compose (plugin v2) tidak ada"; exit 1; }
    v=${v#v}
    [ "$(printf '2.24.4\n%s\n' "$v" | sort -V | head -1)" = 2.24.4 ] || { echo "docker compose $v < 2.24.4 (tag !override)"; exit 1; }
    # PUBLIC_IP (config.env): IP publik server ini bila di belakang NAT (IP publik tidak terlihat di interface).
    mine="${PUBLIC_IP:-} $(hostname -I 2>/dev/null || true)"
    echo "docker compose $v · IP server ini: $mine"
    bad=0
    for h in $(served_hosts); do   # Let's Encrypt memvalidasi lewat host ini → record DNS harus mengarah ke server ini
      ip=$(getent ahostsv4 "$h" | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
      # Semua record harus milik server ini: ACME/pengunjung bisa memilih record mana pun (sisa server lama = gagal).
      other=$(comm -23 <(tr ' ' '\n' <<< "$ip" | grep . | sort -u) <(tr ' ' '\n' <<< "$mine" | grep . | sort -u) | tr '\n' ' ')
      if [ -z "$ip" ]; then echo "  $h → TIDAK ADA RECORD DNS"; ok=
      elif [ -z "$other" ]; then echo "  $h → $ip"; ok=1
      else echo "  $h → $ip: ${other}BUKAN server ini (di belakang NAT? isi PUBLIC_IP di config.env)"; ok=; fi
      [ -n "$ok" ] || [ "$SCHEME" = http ] || bad=1
    done
    for h in $(for p in $ALL_STACKS; do stack_host "$p"; done); do   # server lain (bridge, bus, JWKS, fetch app): belum up = wajar saat deploy pertama
      [[ " $(served_hosts) " == *" $h "* ]] && continue
      t=$(peer_ip "$h") add=(); [ -n "$t" ] && add=(--add-host "$h:$t")
      # Jalur yang sama dengan container (PEER_HOSTS → extra_hosts, kosong = DNS); JWKS GoTrue = stack Supabase itu yang menjawab.
      r=$(docker run --rm "${add[@]}" node:22-alpine node -e 'fetch(process.argv[1], { signal: AbortSignal.timeout(8000) })
        .then(async (r) => console.log(Array.isArray((await r.json()).keys) ? "ok" : `HTTP ${r.status}`))
        .catch((e) => console.log(e.cause?.code ?? e.name))' "$SCHEME://$h/auth/v1/.well-known/jwks.json")
      if [ "$r" = ok ]; then echo "  $h${t:+ ($t)} menjawab"
      else echo "  PERINGATAN: $h${t:+ ($t)} tidak menjawab ($r) — server itu belum up, DNS/PEER_HOSTS salah, atau firewall"; fi
    done
    exit $bad
    ;;
  backup)
    # Dump DB (pg_restore) + file Storage (volume lokal; kosong bila pakai S3) tiap stack yang jalan di server ini.
    load_config
    keep=${BACKUP_KEEP_DAYS:-14} ts=$(date +%Y%m%d%H%M%S) n=0 fail=0
    [[ "$keep" =~ ^[0-9]+$ ]] || { echo "BACKUP_KEEP_DAYS harus angka hari"; exit 1; }
    for p in $STACKS; do
      # all: stack milik server lain (container tidak ada) dilewati; container ada tapi mati = gagal, stack lain tetap di-backup.
      run=$(docker inspect -f '{{.State.Running}}' "$p-db" 2>/dev/null || true)
      if [ "$run" != true ]; then
        [ "$ROLE" = all ] && [ -z "$run" ] && continue
        echo "GAGAL: $p-db tidak jalan — stack $p tidak di-backup"; fail=1; continue
      fi
      b=stack/$p/backups; mkdir -p "$b"
      (umask 077 && docker exec "$p-db" pg_dump -h localhost -U supabase_admin -d postgres -Fc > "$b/db-$ts.dump.tmp")
      mv "$b/db-$ts.dump.tmp" "$b/db-$ts.dump"
      # Lewat container (root): file Storage milik user container, belum tentu terbaca user yang menjalankan deploy.sh.
      (umask 077 && docker run --rm -v "$DEPLOY/stack/$p/volumes/storage":/s:ro node:22-alpine tar czf - -C /s . \
        > "$b/storage-$ts.tgz.tmp")
      mv "$b/storage-$ts.tgz.tmp" "$b/storage-$ts.tgz"
      find "$b" \( -name 'db-*.dump' -o -name 'storage-*.tgz' -o -name '*.tmp' \) -mtime +"$keep" -delete
      echo "$p: $b/db-$ts.dump ($(du -h "$b/db-$ts.dump" | cut -f1)) + $b/storage-$ts.tgz ($(du -h "$b/storage-$ts.tgz" | cut -f1))"
      n=$((n + 1))
    done
    [ "$n" -gt 0 ] || [ "$fail" = 1 ] || { echo "tidak ada stack Supabase di server ini (server app tidak menyimpan data)"; exit 1; }
    exit $fail
    ;;
  bus)
    local_stacks=$(for p in core creator brand; do if [ -d "stack/$p" ]; then echo "$p"; fi; done)
    [ -n "$local_stacks" ] || { echo "tidak ada stack core/creator/brand di server ini"; exit 1; }
    case "$BUS_OP" in
      status)
        for p in $local_stacks; do
          echo "== $p ($(bus_name "$p"))"
          psql_db "$p" -tA -c "select jsonb_pretty(api.health() - 'db')"
          psql_db "$p" -c "select target, seq, topic, attempts, created_at, left(last_error, 120) as last_error from bus.stuck()"
          [ "$p" = core ] && psql_db "$p" -c "select source, pinged_at as watermark, seen_at as ping_terakhir, stuck from ops.bus_peers order by source"
        done
        ;;
      kick)
        for p in $local_stacks; do
          psql_db "$p" -tA -c "with u as (update bus.outbox set next_at = now(), attempts = 0 where sent_at is null and request_id is null returning 1)
                               select '$p: ' || count(*) || ' event dicoba kirim ulang' from u"
        done
        ;;
      skip)
        [ ${#BUS_ARGS[@]} -eq 3 ] || { echo "pakai: deploy.sh bus skip <core|creator|brand> <target admin|creator|brand> <seq kepala antrean (bus status)>"; exit 1; }
        [ -d "stack/${BUS_ARGS[0]}" ] || { echo "stack ${BUS_ARGS[0]} tidak ada di server ini"; exit 1; }
        [[ "${BUS_ARGS[1]}" =~ ^(admin|creator|brand)$ && "${BUS_ARGS[2]}" =~ ^[0-9]+$ ]] || { echo "target/seq tidak valid"; exit 1; }
        echo "event yang dilewati (simpan untuk catatan):"
        psql_db "${BUS_ARGS[0]}" -tA -c "select jsonb_pretty(bus.skip('${BUS_ARGS[1]}', ${BUS_ARGS[2]}))"
        ;;
      reconcile)
        [[ "${BUS_ARGS[0]:-}" =~ ^(admin|creator|brand)$ ]] || { echo "pakai: deploy.sh bus reconcile <admin|creator|brand>"; exit 1; }
        for p in $local_stacks; do
          [ "$(bus_name "$p")" = "${BUS_ARGS[0]}" ] && continue
          tables=$(psql_db "$p" -tA -c "select bus.replica_tables('${BUS_ARGS[0]}')")   # urut FK: induk dulu
          for t in $tables; do   # 1) state dikirim ulang, induk dulu
            psql_db "$p" -tA -c "select '$p → ${BUS_ARGS[0]} $t: ' || bus.resync('$t', '${BUS_ARGS[0]}') || ' baris dikirim ulang'"
          done
          for t in $(echo "$tables" | tac); do   # 2) baris yang tidak ada di sini dihapus di target, anak dulu
            psql_db "$p" -tA -c "select '$p → ${BUS_ARGS[0]} $t: ' || bus.reconcile('$t', '${BUS_ARGS[0]}') || ' kunci direkonsiliasi'"
          done
        done
        ;;
      jobs)
        # Job cron bisnis (lifecycle, release earning, settlement, …) berhenti/jalan; job bus-* tetap (restore, O1-C2).
        [[ "${BUS_ARGS[0]:-}" =~ ^(on|off)$ ]] || { echo "pakai: deploy.sh bus jobs <off|on>"; exit 1; }
        for p in $local_stacks; do
          psql_db "$p" -tA -c "select '$p: ' || count(*) || ' job ${BUS_ARGS[0]}' from (select cron.alter_job(jobid, active := $([ "${BUS_ARGS[0]}" = on ] && echo true || echo false))
                               from cron.job where jobname not like 'bus-%') x"
        done
        ;;
      *) echo "pakai: deploy.sh bus status | kick | skip <stack> <target> <seq> | reconcile <target> | jobs <off|on>"; exit 1 ;;
    esac
    ;;
  admin)
    # Bootstrap admin_super pertama (api.admin_set_role butuh admin_super yang sudah ada); aturan akun admin terpisah (AA-20)
    # tetap berlaku.
    load_config
    [[ "$ADMIN_EMAIL" =~ ^[^@[:space:]\'\"]+@[^@[:space:]\'\"]+\.[a-z]{2,}$ ]] || { echo "pakai: deploy.sh admin email@domain"; exit 1; }
    docker inspect identity-auth >/dev/null 2>&1 || { echo "stack identity belum jalan di server ini (deploy.sh up identity)"; exit 1; }
    uid=$(psql_db identity -tA -v email="$ADMIN_EMAIL" <<'SQL'
select id from auth.users where lower(email) = lower(:'email');
SQL
)
    if [ -z "$uid" ]; then
      # Admin API GoTrue dipanggil dari Postgres (pg_net) dengan service key yang sudah ada di Vault (identity_secret_key):
      # kunci tidak pernah muncul di argumen proses host/container; CLI GoTrue butuh password di argumen → tidak dipakai.
      rid=$(psql_db identity -tA -v email="$ADMIN_EMAIL" <<'SQL'
select net.http_post(
  url := (select decrypted_secret from vault.decrypted_secrets where name = 'identity_url') || '/auth/v1/admin/users',
  headers := jsonb_build_object('Authorization', 'Bearer ' || k.v, 'apikey', k.v, 'Content-Type', 'application/json'),
  body := jsonb_build_object('email', :'email', 'email_confirm', true))
from (select decrypted_secret as v from vault.decrypted_secrets where name = 'identity_secret_key') k;
SQL
)
      [[ "$rid" =~ ^[0-9]+$ ]] || { echo "pg_net tidak mengembalikan id request"; exit 1; }
      for _ in $(seq 1 30); do
        code=$(psql_db identity -tA -c "select status_code from net._http_response where id = $rid")
        [ -n "$code" ] && break
        sleep 1
      done
      [[ "${code:-}" =~ ^2 ]] || { echo "Admin API GoTrue menolak membuat $ADMIN_EMAIL (status ${code:-timeout}; docker logs identity-auth)"; exit 1; }
      uid=$(psql_db identity -tA -v email="$ADMIN_EMAIL" <<'SQL'
select id from auth.users where lower(email) = lower(:'email');
SQL
)
    fi
    [ -n "$uid" ] || { echo "gagal membuat akun $ADMIN_EMAIL"; exit 1; }
    blocked=$(psql_db identity -tA -v uid="$uid" <<'SQL'
select not exists (select 1 from member.platform_roles where user_id = :'uid')
   and exists (select 1 from member.consents where user_id = :'uid' and kind in ('tos_clipper', 'tos_brand'));
SQL
)
    [ "$blocked" = t ] && { echo "akun $ADMIN_EMAIL sudah terdaftar sebagai clipper/brand — admin wajib akun terpisah, pakai email lain"; exit 1; }
    psql_db identity -v uid="$uid" <<'SQL'
with granted as (insert into member.platform_roles (user_id, role) values (:'uid', 'admin_super')
                 on conflict do nothing returning user_id)
insert into member.audit_logs (actor_id, action, target, after)
select null, 'role.grant', 'user:' || user_id, '{"role":"admin_super","via":"deploy.sh admin"}' from granted;
SQL
    echo "admin_super: $ADMIN_EMAIL ($uid) → login di $ADMIN dengan kode OTP email, lalu daftarkan authenticator (MFA wajib)"
    ;;
  *) sed -n '2,/^set /{/^#/p}' "$DEPLOY/deploy.sh"; exit 1 ;;
esac
