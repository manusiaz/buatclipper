#!/usr/bin/env bash
# Bangkitkan types schema api tiap project dari stack lokal yang jalan (scripts/dev-stack.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
for p in core identity brand; do
  supabase gen types typescript --local --schema api --workdir "db/$p" 2>/dev/null > "packages/db-$p/src/types.gen.ts"
done
echo "types: packages/db-{core,identity,brand}/src/types.gen.ts"
