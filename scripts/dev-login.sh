#!/usr/bin/env bash
# Login OTP ke stack identity lokal tanpa browser (kode dibaca dari Mailpit); mencetak access token. Untuk uji API/E2E.
# Pakai: scripts/dev-login.sh <email>
set -euo pipefail
cd "$(dirname "$0")/.."
email="$1"
key=$(grep '^NEXT_PUBLIC_IDENTITY_PUBLISHABLE_KEY=' apps/accounts/.env.local | cut -d= -f2)
since=$(date -u +%s)
curl -sf -X POST http://127.0.0.1:54321/auth/v1/otp -H "apikey: $key" -H 'content-type: application/json' \
  -d "{\"email\":\"$email\",\"create_user\":true}" >/dev/null
for _ in $(seq 1 20); do
  code=$(curl -s "http://127.0.0.1:54324/api/v1/search?query=to:$email" | python3 -c "
import json,sys,re,datetime
for m in json.load(sys.stdin).get('messages',[]):
    t=datetime.datetime.fromisoformat(m['Created'].replace('Z','+00:00')).timestamp()
    r=re.search(r'(\d{6})', m['Subject'])
    if r and t >= $since - 2: print(r.group(1)); break
" || true)
  [ -n "$code" ] && break
  sleep 0.5
done
curl -sf -X POST http://127.0.0.1:54321/auth/v1/verify -H "apikey: $key" -H 'content-type: application/json' \
  -d "{\"type\":\"email\",\"email\":\"$email\",\"token\":\"$code\"}" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])"
