#!/usr/bin/env bash
# Kode Edge Function bersama: sumber tunggal db/core/supabase/functions/_shared, disalin ke project creator & brand (edge runtime
# hanya me-mount folder functions project-nya sendiri). scripts/check-arch.mjs menolak salinan yang berbeda dari sumber.
set -euo pipefail
cd "$(dirname "$0")/.."
FILES="http.ts bridge.ts db.ts bus.ts"
for p in creator brand; do
  mkdir -p "db/$p/supabase/functions/_shared"
  for f in $FILES; do cp "db/core/supabase/functions/_shared/$f" "db/$p/supabase/functions/_shared/$f"; done
  cp db/core/supabase/schemas/bus/bus.sql "db/$p/supabase/schemas/bus/bus.sql"
  cp db/core/supabase/functions/deno.json db/core/supabase/functions/import_map.json "db/$p/supabase/functions/"
done
