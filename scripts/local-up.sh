#!/usr/bin/env bash
# Jalankan seluruh sistem di laptop sendiri: 4 database lokal (identity, admin, creator, brand) + 5 app.
#   scripts/local-up.sh              cek prasyarat, pnpm install, nyalakan stack (ulang sekali bila gagal), lalu pnpm dev
#   scripts/local-up.sh --no-dev     sama, tanpa menjalankan app (stack saja)
#   scripts/local-up.sh admin EMAIL  buat akun admin_super lokal (akun terpisah dari clipper/brand, sama dengan deploy.sh admin)
set -euo pipefail
cd "$(dirname "$0")/.."

q() { docker exec -i supabase_db_clipper-identity psql -U postgres -d postgres -qtAX -v ON_ERROR_STOP=1 "$@"; }

if [ "${1:-}" = admin ]; then
  email="${2:-}"
  [[ "$email" =~ ^[^@[:space:]\'\"]+@[^@[:space:]\'\"]+\.[a-z]{2,}$ ]] || { echo "pakai: scripts/local-up.sh admin email@domain"; exit 1; }
  docker inspect supabase_db_clipper-identity >/dev/null 2>&1 || { echo "stack belum jalan: scripts/local-up.sh --no-dev dulu"; exit 1; }
  uid=$(q -v email="$email" <<'SQL'
select id from auth.users where lower(email) = lower(:'email');
SQL
)
  if [ -z "$uid" ]; then
    # Admin API GoTrue dari Postgres (pg_net) memakai service key di Vault: kunci tidak muncul di argumen proses.
    rid=$(q -v email="$email" <<'SQL'
select net.http_post(
  url := (select decrypted_secret from vault.decrypted_secrets where name = 'identity_url') || '/auth/v1/admin/users',
  headers := jsonb_build_object('Authorization', 'Bearer ' || k.v, 'apikey', k.v, 'Content-Type', 'application/json'),
  body := jsonb_build_object('email', :'email', 'email_confirm', true))
from (select decrypted_secret as v from vault.decrypted_secrets where name = 'identity_secret_key') k;
SQL
)
    code=""
    for _ in $(seq 1 30); do
      code=$(q -c "select status_code from net._http_response where id = $rid")
      [ -n "$code" ] && break
      sleep 1
    done
    [[ "$code" =~ ^2 ]] || { echo "Admin API menolak membuat $email (status ${code:-timeout})"; exit 1; }
    uid=$(q -v email="$email" <<'SQL'
select id from auth.users where lower(email) = lower(:'email');
SQL
)
  fi
  blocked=$(q -v uid="$uid" <<'SQL'
select not exists (select 1 from member.platform_roles where user_id = :'uid')
   and exists (select 1 from member.consents where user_id = :'uid' and kind in ('tos_clipper', 'tos_brand'));
SQL
)
  [ "$blocked" = t ] && { echo "$email sudah terdaftar sebagai clipper/brand — admin wajib akun terpisah, pakai email lain"; exit 1; }
  q -v uid="$uid" <<'SQL'
with granted as (insert into member.platform_roles (user_id, role) values (:'uid', 'admin_super')
                 on conflict do nothing returning user_id)
insert into member.audit_logs (actor_id, action, target, after)
select null, 'role.grant', 'user:' || user_id, '{"role":"admin_super","via":"local-up.sh admin"}' from granted;
SQL
  echo "admin_super: $email → login di http://admin.clipper.localhost:3004 (kode OTP di http://127.0.0.1:54324), lalu daftarkan authenticator"
  exit 0
fi

missing=""
command -v docker >/dev/null || missing+=" docker"
command -v pnpm >/dev/null || missing+=" pnpm"
command -v supabase >/dev/null || missing+=" supabase-cli"
command -v node >/dev/null || missing+=" node"
[ -z "$missing" ] || { echo "belum terpasang:$missing"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker belum menyala"; exit 1; }
[ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ] || { echo "butuh Node ≥ 22"; exit 1; }

pnpm install
# Run pertama setelah Docker baru menyala kadang gagal tanpa pesan; run kedua (idempoten) jalan.
bash scripts/dev-stack.sh || { echo "dev-stack gagal, mengulang sekali…"; bash scripts/dev-stack.sh; }

cat <<'TXT'

Siap. Alamat:
  Landing   http://clipper.localhost:3000
  Akun      http://accounts.clipper.localhost:3001
  Clipper   http://app.clipper.localhost:3002
  Brand     http://brand.clipper.localhost:3003
  Admin     http://admin.clipper.localhost:3004   (akun: scripts/local-up.sh admin email@domain)
  Email OTP http://127.0.0.1:54324
TXT
[ "${1:-}" = --no-dev ] || exec pnpm dev
