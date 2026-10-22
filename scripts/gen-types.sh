#!/usr/bin/env bash
# Bangkitkan types schema api kedua project dari SQL deklaratif (Postgres lokal + stub, tanpa stack Supabase).
# Dengan stack jalan, setara: supabase gen types typescript --local --schema api --workdir db/<project>
set -euo pipefail
cd "$(dirname "$0")/.."
for p in core identity; do
  python3 db/test-local/load.py "$p" "t_types_$p" >/dev/null
  supabase gen types typescript --db-url "postgresql://postgres@127.0.0.1:5432/t_types_$p" --schema api 2>/dev/null \
    > "packages/db-$p/src/types.gen.ts"
done
# Project brand: dari stack lokal yang jalan (scripts/dev-stack.sh).
supabase gen types typescript --local --schema api --workdir db/brand > packages/db-brand/src/types.gen.ts
echo "types: packages/db-{core,identity,brand}/src/types.gen.ts"
