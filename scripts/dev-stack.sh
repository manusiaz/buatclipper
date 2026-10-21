#!/usr/bin/env bash
# Stack lokal penuh: dua project Supabase (identity :54321, core :55321) — network docker terpisah (alias kong/db sama),
# panggilan lintas stack lewat gateway host (host.docker.internal) —, secret dev Edge Function,
# Vault untuk pg_cron, dan apps/*/.env.local untuk 5 app. Idempoten. Host dev: *.clipper.localhost.
# Pakai: scripts/dev-stack.sh [--reset]   (--reset = supabase db reset kedua project, data lokal hilang)
set -euo pipefail
cd "$(dirname "$0")/.."
export SUPABASE_INTERNAL_IMAGE_REGISTRY="${SUPABASE_INTERNAL_IMAGE_REGISTRY:-docker.io}"
SECRETS=db/.dev-secrets.env
DOMAIN=clipper.localhost
WEB="http://$DOMAIN:3000" ACC="http://accounts.$DOMAIN:3001" APP="http://app.$DOMAIN:3002" BRAND="http://brand.$DOMAIN:3003" ADMIN="http://admin.$DOMAIN:3004"

rand() { openssl rand -base64 32 | tr -d '\n'; }
if [ ! -f "$SECRETS" ]; then
  vapid=$(deno run -A npm:web-push@3.6.7 generate-vapid-keys --json)
  cat > "$SECRETS" <<EOF
BRIDGE_SECRET_CORE_TO_IDENTITY=$(rand)
BRIDGE_SECRET_IDENTITY_TO_CORE=$(rand)
PII_HMAC_KEY=$(rand)
PII_ENC_KEYS='{"1":"'$(rand)'"}'
PII_ENC_KEY_VERSION=1
UNSUBSCRIBE_SECRET=$(rand)
DISBURSE_CALLBACK_TOKEN=$(rand)
VAPID_PUBLIC_KEY=$(echo "$vapid" | python3 -c 'import json,sys;print(json.load(sys.stdin)["publicKey"])')
VAPID_PRIVATE_KEY=$(echo "$vapid" | python3 -c 'import json,sys;print(json.load(sys.stdin)["privateKey"])')
EOF
fi
set -a; . "$SECRETS"; set +a

# Kunci signing JWT lokal (ES256), sama untuk kedua project: core memverifikasi JWT identity (produksi: Custom OIDC/JWKS).
KEYS=db/identity/supabase/dev-keys/signing_keys.json
if [ ! -f "$KEYS" ]; then
  mkdir -p db/identity/supabase/dev-keys db/core/supabase/dev-keys
  supabase gen signing-key --algorithm ES256 2>/dev/null | python3 -c 'import json,sys; json.dump([json.load(sys.stdin)], sys.stdout)' > "$KEYS"
fi
cp "$KEYS" db/core/supabase/dev-keys/signing_keys.json

# Nilai non-rahasia. Lintas stack: host.docker.internal:<port host>; dalam stack sendiri: nama container.
export IDENTITY_ISSUER="http://127.0.0.1:54321/auth/v1"
export IDENTITY_PUBLIC_URL="http://127.0.0.1:54321"
export IDENTITY_JWKS_URL="http://host.docker.internal:54321/auth/v1/.well-known/jwks.json"
export IDENTITY_FUNCTIONS_URL="http://host.docker.internal:54321/functions/v1"
export CORE_FUNCTIONS_URL="http://host.docker.internal:55321/functions/v1"
export APP_ORIGINS="$ACC,$APP,$BRAND,$ADMIN"
export SOCIAL_REDIRECT_ALLOWLIST=$(for p in tiktok instagram youtube threads facebook x; do printf '%s/api/oauth/%s/callback,' "$APP" "$p"; done | sed 's/,$//')
export UNSUBSCRIBE_BASE_URL="http://127.0.0.1:55321/functions/v1/notify/unsubscribe"
export EMAIL_FROM="Clipper <no-reply@notif.$DOMAIN>" RESEND_API_KEY="" MAILPIT_URL="http://supabase_inbucket_clipper-identity:8025"
export APP_URL="$APP" BRAND_URL="$BRAND" ACCOUNTS_URL="$ACC" ADMIN_URL="$ADMIN" VAPID_SUBJECT="mailto:dev@$DOMAIN"
export DISBURSE_PROVIDER=mock XENDIT_SECRET_KEY=""
# APNS_* (Live Activity iOS) kosong = fitur mati; isi dari shell untuk uji ke APNs sandbox.
for v in TIKTOK_CLIENT_KEY TIKTOK_CLIENT_SECRET META_APP_ID META_APP_SECRET GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET YOUTUBE_API_KEY \
         THREADS_APP_ID THREADS_APP_SECRET FACEBOOK_APP_ID FACEBOOK_APP_SECRET X_CLIENT_ID X_CLIENT_SECRET \
         APNS_KEY_ID APNS_TEAM_ID APNS_PRIVATE_KEY APNS_BUNDLE_ID APNS_ENV; do
  export "$v=${!v:-}"
done

for p in identity core; do
  supabase start --workdir "db/$p" -x vector,logflare,studio,imgproxy >/dev/null
  # Setelah Docker/mesin restart hanya container db yang hidup lagi; `supabase start` menganggap stack sudah jalan.
  if [ "$(docker inspect -f '{{.State.Running}}' "supabase_edge_runtime_clipper-$p" 2>/dev/null)" != true ]; then
    supabase stop --workdir "db/$p" >/dev/null
    supabase start --workdir "db/$p" -x vector,logflare,studio,imgproxy >/dev/null
  fi
  [ "${1:-}" = "--reset" ] && supabase db reset --workdir "db/$p" >/dev/null
done

# Container edge runtime tidak selalu punya akses internet: unduh paket npm di host lalu salin ke cache Deno container.
DENO_NPM="$(deno info --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["denoDir"])')/npm"
for p in identity core; do
  (cd "db/$p/supabase/functions" && deno cache */index.ts >/dev/null)
  docker exec "supabase_edge_runtime_clipper-$p" mkdir -p /root/.cache/deno/npm
  docker cp "$DENO_NPM/registry.npmjs.org" "supabase_edge_runtime_clipper-$p:/root/.cache/deno/npm/" >/dev/null
done

status() { supabase status --workdir "db/$1" -o env 2>/dev/null | grep "^$2=" | cut -d= -f2- | tr -d '"'; }
ID_PUB=$(status identity PUBLISHABLE_KEY); CORE_PUB=$(status core PUBLISHABLE_KEY)
# Kunci cron = nilai yang dilihat Edge Function sendiri (SUPABASE_SERVICE_ROLE_KEY di container berbeda dengan yang
# dicetak `supabase status`). Produksi: isi Vault dengan secret key yang sama dengan env fungsi (Fase 0).
fnkey() { docker exec "supabase_edge_runtime_clipper-$1" printenv SUPABASE_SERVICE_ROLE_KEY; }
ID_SVC=$(fnkey identity); CORE_SVC=$(fnkey core)

# Vault: URL + kunci yang dipakai pg_cron/pg_net memanggil Edge Function project sendiri (policy:fn-cron-key).
vault() { # port name value
  psql "postgresql://postgres:postgres@127.0.0.1:$1/postgres" -qtAX -v ON_ERROR_STOP=1 -c \
    "do \$\$ begin
       if exists (select 1 from vault.secrets where name = '$2') then
         perform vault.update_secret((select id from vault.secrets where name = '$2'), '$3');
       else perform vault.create_secret('$3', '$2'); end if; end \$\$" >/dev/null
}
vault 54322 identity_url "http://supabase_kong_clipper-identity:8000"
vault 54322 identity_secret_key "$ID_SVC"
vault 55322 core_url "http://supabase_kong_clipper-core:8000"
vault 55322 core_secret_key "$CORE_SVC"

for a in web accounts clipper brand admin; do
  {
    echo "NEXT_PUBLIC_CORE_URL=http://127.0.0.1:55321"
    echo "NEXT_PUBLIC_CORE_PUBLISHABLE_KEY=$CORE_PUB"
    [ "$a" != web ] && echo "NEXT_PUBLIC_IDENTITY_URL=http://127.0.0.1:54321" && echo "NEXT_PUBLIC_IDENTITY_PUBLISHABLE_KEY=$ID_PUB"
    echo "NEXT_PUBLIC_COOKIE_DOMAIN=.$DOMAIN"
    echo "NEXT_PUBLIC_WEB_URL=$WEB"; echo "NEXT_PUBLIC_ACCOUNTS_URL=$ACC"; echo "NEXT_PUBLIC_APP_URL=$APP"
    echo "NEXT_PUBLIC_BRAND_URL=$BRAND"; echo "NEXT_PUBLIC_ADMIN_URL=$ADMIN"
    [ "$a" = clipper ] && echo "NEXT_PUBLIC_VAPID_PUBLIC_KEY=$VAPID_PUBLIC_KEY"
  } > "apps/$a/.env.local"
done
# App native (Expo): uji lewat build web (`pnpm --filter @clipper/mobile web`). Emulator / HP: MOBILE_HOST = alamat laptop
# dari perangkat itu (emulator Android 10.0.2.2, HP fisik IP LAN laptop), mis. MOBILE_HOST=192.168.1.10 scripts/dev-stack.sh.
MH="${MOBILE_HOST:-127.0.0.1}"
{
  echo "EXPO_PUBLIC_IDENTITY_URL=http://$MH:54321"; echo "EXPO_PUBLIC_IDENTITY_PUBLISHABLE_KEY=$ID_PUB"
  echo "EXPO_PUBLIC_CORE_URL=http://$MH:55321"; echo "EXPO_PUBLIC_CORE_PUBLISHABLE_KEY=$CORE_PUB"
  echo "EXPO_PUBLIC_APP_URL=$APP"; echo "EXPO_PUBLIC_ACCOUNTS_URL=$ACC"; echo "EXPO_PUBLIC_BRAND_URL=$BRAND"; echo "EXPO_PUBLIC_WEB_URL=$WEB"
} > apps/mobile/.env.local
echo "stack lokal siap: identity http://127.0.0.1:54321 (email: http://127.0.0.1:54324), core http://127.0.0.1:55321"
