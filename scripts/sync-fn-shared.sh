#!/usr/bin/env bash
# Kode bersama (Edge Function _shared + SQL bus/_base/_auth): sumber tunggal db/core/supabase/functions/_shared, disalin ke project creator & brand (edge runtime
# hanya me-mount folder functions project-nya sendiri). scripts/check-arch.mjs menolak salinan yang berbeda dari sumber.
set -euo pipefail
cd "$(dirname "$0")/.."
FILES="http.ts bridge.ts db.ts bus.ts auth.ts testing.ts"
for p in creator brand; do
  mkdir -p "db/$p/supabase/functions/_shared"
  for f in $FILES; do cp "db/core/supabase/functions/_shared/$f" "db/$p/supabase/functions/_shared/$f"; done
  for f in bus/bus.sql ops/_base.sql ops/_auth.sql; do cp "db/core/supabase/schemas/$f" "db/$p/supabase/schemas/$f"; done
  [ "$p" = brand ] && for f in _org_helpers _content_helpers; do cp "db/core/supabase/schemas/market/$f.sql" "db/brand/supabase/schemas/market/$f.sql"; done
  cp db/core/supabase/functions/deno.json db/core/supabase/functions/import_map.json "db/$p/supabase/functions/"
done
