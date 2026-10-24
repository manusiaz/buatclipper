#!/usr/bin/env node
// Allowlist bus per penerima (db/<p>/supabase/schemas/bus/accept.sql): rep.row hanya untuk tabel & kolom yang dikirim pemiliknya
// (trigger bus.replicate('<target>:<kolom>') pengirim; kunci primer selalu boleh), topik lain hanya dari project yang memang
// memanggil bus.emit('<target>', '<topik>'). Tanpa ini satu secret bus yang bocor = tulis tabel / panggil handler apa pun di
// penerima (uang admin, sanksi, hapus akun). --check: gagal bila file tidak sesuai.
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname;
const DIRS = { admin: 'core', creator: 'creator', brand: 'brand' };

const sqlFiles = (dir) => readdirSync(dir).sort().flatMap((f) => {
  const p = join(dir, f);
  return statSync(p).isDirectory() ? sqlFiles(p) : f.endsWith('.sql') ? [p] : [];
});

const accepts = Object.fromEntries(Object.keys(DIRS).map((r) => [r, []]));
const topics = Object.fromEntries(Object.keys(DIRS).map((r) => [r, new Set()]));
for (const [source, dir] of Object.entries(DIRS)) {
  for (const f of sqlFiles(join(ROOT, 'db', dir, 'supabase/schemas'))) {
    const re = /\bon\s+([a-z_]+\.[a-z_]+)\s+for each row\s+execute function bus\.replicate\(([^)]*)\)/g;
    for (const [, table, args] of readFileSync(f, 'utf8').matchAll(re)) {
      for (const [, target, cols] of args.matchAll(/'([a-z]+):([a-z_,]+)'/g)) accepts[target].push([source, table, cols.split(',')]);
    }
    for (const [, target, topic] of readFileSync(f, 'utf8').matchAll(/bus\.emit\('([a-z]+)',\s*'([a-z_.]+)'/g)) {
      if (target !== source) topics[target].add(`('${source}', '${topic}')`);
    }
  }
}

const check = process.argv.includes('--check');
let stale = false;
for (const [receiver, dir] of Object.entries(DIRS)) {
  const rows = accepts[receiver].sort((a, b) => (a[0] + a[1]).localeCompare(b[0] + b[1]))
    .map(([s, t, c]) => `    ('${s}', '${t}', array[${c.map((x) => `'${x}'`).join(', ')}])`);
  const sql = `-- DIBANGKITKAN scripts/gen-bus-accept.mjs dari trigger bus.replicate pengirim — jangan diedit tangan.
-- Kolom yang boleh ditulis tiap pengirim lewat rep.row di DB ini (bus.apply_row); selain itu ditolak.
create function bus.accepts(p_source text, p_table text) returns text[]
language sql immutable set search_path = '' as $$
  select v.cols from (values
${rows.join(',\n')}
  ) v(source, tbl, cols) where v.source = p_source and v.tbl = p_table;
$$;
-- Topik selain rep.row yang boleh dikirim tiap pengirim ke DB ini (bus.emit di kode pengirim).
create function bus.accepts_topic(p_source text, p_topic text) returns boolean
language sql immutable set search_path = '' as $$
  select ${topics[receiver].size ? `(p_source, p_topic) in (\n${[...topics[receiver]].sort().map((t) => `    ${t}`).join(',\n')}\n  )` : 'false'};
$$;
revoke execute on function bus.accepts(text, text), bus.accepts_topic(text, text) from public;
`;
  const file = join(ROOT, 'db', dir, 'supabase/schemas/bus/accept.sql');
  let cur = null;
  try { cur = readFileSync(file, 'utf8'); } catch {}
  if (cur === sql) continue;
  if (check) { console.error(`db/${dir}/supabase/schemas/bus/accept.sql: tidak sesuai trigger bus.replicate (jalankan node scripts/gen-bus-accept.mjs)`); stale = true; }
  else { writeFileSync(file, sql); console.log(`db/${dir}/supabase/schemas/bus/accept.sql: ${rows.length} tabel`); }
}
process.exit(stale ? 1 : 0);
