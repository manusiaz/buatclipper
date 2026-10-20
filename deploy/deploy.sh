#!/usr/bin/env bash
# Deploy self-hosted Clipper Platform di satu server Docker: 2 stack Supabase resmi (identity, core) + 5 app Next.js +
# Caddy (HTTPS otomatis Let's Encrypt). Idempoten: jalankan ulang untuk update (migration baru, fungsi, app).
#
#   cp deploy/config.env.example deploy/config.env && $EDITOR deploy/config.env
#   deploy/deploy.sh up       # secret (sekali) → stack Supabase → migration + seed + bucket + Vault → fungsi → app + Caddy
#   deploy/deploy.sh down     # matikan semua; data tetap di deploy/stack/*/volumes
#   deploy/deploy.sh status
#
# Syarat server: Docker Engine + compose ≥ 2.24, git, port 80/443 terbuka, DNS A {DOMAIN} dan
# accounts./app./brand./admin./auth./api.{DOMAIN} → IP server. Backup: deploy/secrets.env + deploy/stack/*/volumes/db/data.
# Studio (dashboard DB) tidak publik: ssh -L 8001:127.0.0.1:8001 server → http://localhost:8001 (user supabase,
# password {IDENTITY|CORE}_DASHBOARD_PASSWORD di secrets.env); core di port 8002.
set -euo pipefail
cd "$(dirname "$0")"
DEPLOY=$PWD ROOT=$(cd .. && pwd)
# supabase/supabase docker/ (compose self-hosted resmi) yang diuji dengan deploy ini.
SUPABASE_REF=${SUPABASE_REF:-d897e1462ad33ee9c7daba8cfee8f14e303c0cf5}

[ -f config.env ] || { echo "deploy/config.env belum ada: cp deploy/config.env.example deploy/config.env lalu isi"; exit 1; }
set -a; . ./config.env; set +a
SCHEME=${SCHEME:-https}
[[ "${DOMAIN:-}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || { echo "DOMAIN tidak valid: '${DOMAIN:-}'"; exit 1; }
[[ "$SCHEME" =~ ^https?$ ]] || { echo "SCHEME harus https atau http"; exit 1; }
[ -n "${SMTP_PASS:-}" ] || echo "PERINGATAN: SMTP_PASS kosong — email kode login (OTP) tidak akan terkirim"
[ -n "${RESEND_API_KEY:-}" ] || echo "PERINGATAN: RESEND_API_KEY kosong — email notifikasi platform tidak akan terkirim"
WEB="$SCHEME://$DOMAIN" ACC="$SCHEME://accounts.$DOMAIN" APP="$SCHEME://app.$DOMAIN" BRAND="$SCHEME://brand.$DOMAIN"
ADMIN="$SCHEME://admin.$DOMAIN" AUTH="$SCHEME://auth.$DOMAIN" API="$SCHEME://api.$DOMAIN"

node_run() { docker run --rm -u "$(id -u):$(id -g)" -v "$DEPLOY":/w -v "$ROOT/db":/db:ro -w /w node:22-alpine node "$@"; }

# secrets.env = KEY=value literal (JSON/JWT), dibaca tanpa evaluasi shell.
load_secrets() {
  [ -f secrets.env ] || node_run keys.mjs secrets.env
  while IFS='=' read -r k v; do [ -n "$k" ] && export "$k=$v"; done < secrets.env
}

setenv() { # file key value — ganti/tambah baris tanpa menafsirkan isi value
  K="$2" V="$3" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
    index($0, k "=") == 1 { if (!done) print k "=" v; done = 1; next } { print }
    END { if (!done) print k "=" v }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
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
prepare_stack() { # identity|core
  local p=$1 P=${1^^} dir=stack/$1
  mkdir -p "$dir"
  copy_tree stack/.supabase/docker "$dir" --exclude=./volumes/db/data --exclude=./volumes/storage --exclude=./volumes/functions
  mkdir -p "$dir/volumes/functions" "$dir/volumes/storage"
  cp supabase/common.yml "$dir/clipper.common.yml"; cp "supabase/$p.yml" "$dir/clipper.$p.yml"
  [ -f "$dir/.env" ] || cp "$dir/.env.example" "$dir/.env"
  local e=$dir/.env pub
  [ "$p" = identity ] && pub=$AUTH || pub=$API
  # EXTRA_COMPOSE_FILES (config.env, pisah ':'): override tambahan, mis. docker-compose.s3.yml resmi untuk storage S3.
  setenv "$e" COMPOSE_FILE "docker-compose.yml:clipper.common.yml:clipper.$p.yml${EXTRA_COMPOSE_FILES:+:$EXTRA_COMPOSE_FILES}"
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
  setenv "$e" AUTH_HOST "auth.$DOMAIN"; setenv "$e" API_HOST "api.$DOMAIN"
  setenv "$e" IDENTITY_PUBLIC_URL "$AUTH"; setenv "$e" CORE_PUBLIC_URL "$API"
  setenv "$e" BRIDGE_SECRET_CORE_TO_IDENTITY "$BRIDGE_SECRET_CORE_TO_IDENTITY"
  setenv "$e" BRIDGE_SECRET_IDENTITY_TO_CORE "$BRIDGE_SECRET_IDENTITY_TO_CORE"
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
    for k in PII_HMAC_KEY PII_ENC_KEYS PII_ENC_KEY_VERSION VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY DISBURSE_CALLBACK_TOKEN; do
      setenv "$e" "$k" "${!k}"
    done
    for k in RESEND_API_KEY EMAIL_FROM XENDIT_SECRET_KEY; do setenv "$e" "$k" "${!k:-}"; done
    setenv "$e" DISBURSE_PROVIDER "${DISBURSE_PROVIDER:-mock}"
    setenv "$e" VAPID_SUBJECT "mailto:${SMTP_ADMIN_EMAIL:-admin@$DOMAIN}"
    setenv "$e" APP_URL "$APP"; setenv "$e" BRAND_URL "$BRAND"; setenv "$e" ACCOUNTS_URL "$ACC"; setenv "$e" ADMIN_URL "$ADMIN"
  else
    setenv "$e" GW_PORT 8002; setenv "$e" DB_PORT 5434
    setenv "$e" STORAGE_FILE_SIZE_LIMIT 524288000   # campaign-assets 500 MiB
    setenv "$e" SITE_URL "$APP"
    setenv "$e" DISABLE_SIGNUP true; setenv "$e" ENABLE_EMAIL_SIGNUP false
    setenv "$e" IDENTITY_ISSUER "$AUTH/auth/v1"
    setenv "$e" SOCIAL_REDIRECT_ALLOWLIST \
      "$(for x in tiktok instagram youtube threads facebook x; do printf '%s/api/oauth/%s/callback,' "$APP" "$x"; done | sed 's/,$//')"
    setenv "$e" UNSUBSCRIBE_SECRET "$UNSUBSCRIBE_SECRET"
    for k in TIKTOK_CLIENT_KEY TIKTOK_CLIENT_SECRET META_APP_ID META_APP_SECRET GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET YOUTUBE_API_KEY \
             THREADS_APP_ID THREADS_APP_SECRET FACEBOOK_APP_ID FACEBOOK_APP_SECRET X_CLIENT_ID X_CLIENT_SECRET; do
      setenv "$e" "$k" "${!k:-}"
    done
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
  for f in "$ROOT/db/$p/supabase/migrations/"*.sql; do
    v=$(basename "$f" .sql); n=${v#*_}; v=${v%%_*}
    [ -n "$(psql_db "$p" -tA -c "select 1 from supabase_migrations.schema_migrations where version = '$v'")" ] && continue
    echo "  $p: migration $v $n"
    { cat "$f"; printf "\ninsert into supabase_migrations.schema_migrations (version, name) values ('%s', '%s');\n" "$v" "$n"; } \
      | psql_db "$p" -1
  done
  psql_db "$p" < "$ROOT/db/$p/supabase/seed.sql"
  node_run buckets.mjs "/db/$p/supabase/config.toml" | psql_db "$p"
  if [ "$p" = core ]; then
    psql_db core -v iss="$AUTH/auth/v1" <<'SQL'
update ops.settings set value = to_jsonb(:'iss'::text) where key = 'auth.identity_issuer';
SQL
  else
    psql_db identity -v web="https://$DOMAIN" <<'SQL'   # legal_versions.url wajib https (CHECK)
update member.legal_versions set url = :'web' || substr(url, length('https://clipper.localhost') + 1)
 where url like 'https://clipper.localhost/%';
SQL
  fi
}

apps_env() {
  {
    echo "DOMAIN=$DOMAIN"; echo "SCHEME=$SCHEME"; echo "ACME_EMAIL=${ACME_EMAIL:-}"
    echo "NEXT_PUBLIC_IDENTITY_URL=$AUTH"; echo "NEXT_PUBLIC_IDENTITY_PUBLISHABLE_KEY=$IDENTITY_ANON_KEY"
    echo "NEXT_PUBLIC_CORE_URL=$API"; echo "NEXT_PUBLIC_CORE_PUBLISHABLE_KEY=$CORE_ANON_KEY"
    echo "NEXT_PUBLIC_COOKIE_DOMAIN=.$DOMAIN"
    echo "NEXT_PUBLIC_WEB_URL=$WEB"; echo "NEXT_PUBLIC_ACCOUNTS_URL=$ACC"; echo "NEXT_PUBLIC_APP_URL=$APP"
    echo "NEXT_PUBLIC_BRAND_URL=$BRAND"; echo "NEXT_PUBLIC_ADMIN_URL=$ADMIN"
    echo "NEXT_PUBLIC_VAPID_PUBLIC_KEY=$VAPID_PUBLIC_KEY"; echo "NEXT_PUBLIC_TURNSTILE_SITE_KEY=${NEXT_PUBLIC_TURNSTILE_SITE_KEY:-}"
  } > apps.env
}
apps() { docker compose -f apps.yml --env-file apps.env -p clipper-apps "$@"; }

case "${1:-}" in
  up)
    load_secrets
    docker network inspect clipper >/dev/null 2>&1 || docker network create clipper >/dev/null
    fetch_supabase
    for p in identity core; do
      prepare_stack "$p"
      echo "stack $p: start"
      # PostgREST baru sehat setelah schema api ada (migration) → --wait hanya setelah migrate.
      compose "$p" up -d --remove-orphans
      wait_healthy "$p" db auth storage
      migrate "$p"
      compose "$p" restart functions rest >/dev/null   # muat ulang fungsi, env, dan schema cache
      compose "$p" up -d --wait
    done
    apps_env
    echo "app: build + start"
    apps build
    apps up -d --remove-orphans
    echo "siap: $WEB · $ACC · $APP · $BRAND · $ADMIN (API: $AUTH, $API)"
    ;;
  down)
    apps down 2>/dev/null || true
    for p in core identity; do [ -d "stack/$p" ] && compose "$p" down; done
    ;;
  status)
    for p in identity core; do [ -d "stack/$p" ] && compose "$p" ps --format 'table {{.Name}}\t{{.Status}}'; done
    [ -f apps.env ] && apps ps --format 'table {{.Name}}\t{{.Status}}'
    ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
