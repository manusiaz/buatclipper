#!/usr/bin/env node
// Katalog endpoint per database → docs/endpoints/<db>.md, dibangkitkan dari katalog DB yang jalan (view & RPC schema api +
// hak akses anon/authenticated/service_role), komentar di file skema, dan Edge Function di db/<p>/supabase/functions.
//   pnpm endpoints            (butuh scripts/dev-stack.sh)   ·   ENDPOINTS_DB_<NAMA>=postgresql://… untuk DB lain
import { execFileSync } from 'node:child_process';
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = new URL('..', import.meta.url).pathname;
const DBS = [
  { name: 'identity', dir: 'identity', port: 54322, api: 54321, host: 'auth', what: 'akun, login, PII (KYC, rekening), consent, push' },
  { name: 'admin', dir: 'core', port: 55322, api: 55321, host: 'api', what: 'uang (ledger, pool, invoice, payout), claim, review & fraud, notifikasi, config; replika profil/org/campaign/submisi' },
  { name: 'creator', dir: 'creator', port: 56322, api: 56321, host: 'creator-api', what: 'profil & avatar, akun sosmed + token, submisi, snapshot views, Edge Function sosmed' },
  { name: 'brand', dir: 'brand', port: 57322, api: 57321, host: 'brand-api', what: 'org, tim, undangan, agency, isi campaign + aset/cover' },
];

const psqlJson = (url, sql) => JSON.parse(execFileSync('psql', [url, '-X', '-qtAc', sql], { encoding: 'utf8' }).trim() || '[]');

function sqlFiles(dir) {
  return readdirSync(dir).flatMap((f) => {
    const p = join(dir, f);
    return statSync(p).isDirectory() ? sqlFiles(p) : f.endsWith('.sql') ? [p] : [];
  });
}

/** Komentar `--` tepat di atas `create function|view api.<nama>` (kalimat pertama). */
function comments(dir) {
  const out = {};
  for (const f of sqlFiles(dir)) {
    const lines = readFileSync(f, 'utf8').split('\n');
    lines.forEach((l, i) => {
      const m = /^create (?:or replace )?(?:function|view) api\.(\w+)/.exec(l);
      if (!m || out[m[1]]) return;
      const block = [];
      for (let j = i - 1; j >= 0 && lines[j].startsWith('--'); j--) block.unshift(lines[j].replace(/^--\s?/, ''));
      const text = block.join(' ').replace(/\s+/g, ' ').trim();
      const first = /^(.+?\.)(\s|$)/.exec(text)?.[1] ?? text;
      out[m[1]] = (first.length > 240 ? first.slice(0, 237) + '…' : first).replace(/\|/g, '/');
    });
  }
  return out;
}

const who = (r) => [r.anon && 'anon', r.auth && 'user (JWT identity)', r.svc && 'server (secret key)'].filter(Boolean).join(', ') || 'tidak ada (internal)';

for (const db of DBS) {
  const url = process.env[`ENDPOINTS_DB_${db.name.toUpperCase()}`] ?? `postgresql://postgres:postgres@127.0.0.1:${db.port}/postgres`;
  const views = psqlJson(url, `select coalesce(json_agg(json_build_object('name', c.relname, 'anon', has_table_privilege('anon', c.oid, 'select'),
      'auth', has_table_privilege('authenticated', c.oid, 'select')) order by c.relname), '[]')
    from pg_class c where c.relnamespace = 'api'::regnamespace and c.relkind = 'v'`);
  const fns = psqlJson(url, `select coalesce(json_agg(json_build_object('name', p.proname, 'args', pg_get_function_identity_arguments(p.oid),
      'anon', has_function_privilege('anon', p.oid, 'execute'), 'auth', has_function_privilege('authenticated', p.oid, 'execute'),
      'svc', has_function_privilege('service_role', p.oid, 'execute')) order by p.proname), '[]')
    from pg_proc p where p.pronamespace = 'api'::regnamespace`);
  const doc = comments(join(ROOT, 'db', db.dir, 'supabase/schemas'));
  const fnDir = join(ROOT, 'db', db.dir, 'supabase/functions');
  const edge = readdirSync(fnDir).filter((d) => !d.startsWith('_') && statSync(join(fnDir, d)).isDirectory()).map((d) => {
    const first = readFileSync(join(fnDir, d, 'index.ts'), 'utf8').split('\n')[0].replace(/^\/\/\s*/, '');
    return { name: d, desc: first.replace(/^[\w-]+\/[\w-]+\s+—\s*/, '').replace(/\|/g, '/') };
  });

  const L = [];
  L.push(`# Endpoint DB ${db.name}`, '');
  L.push(`Isi: ${db.what}. Folder: \`db/${db.dir}\`. Dibangkitkan \`pnpm endpoints\` dari DB yang jalan — jangan diedit tangan.`, '');
  L.push('| | URL dasar |', '|---|---|');
  L.push(`| Produksi | \`https://${db.host}.{DOMAIN}\` |`, `| Lokal (dev-stack) | \`http://127.0.0.1:${db.api}\` |`, '');
  L.push('Header: `apikey: <publishable key DB ini>`; untuk user `Authorization: Bearer <JWT sesi identity>` (semua DB percaya issuer',
    'identity yang sama); Data API memakai schema `api` (`Accept-Profile: api` untuk GET, `Content-Profile: api` untuk POST).', '');
  L.push('Health: ' + (fns.some((f) => f.name === 'health')
    ? '`POST /rest/v1/rpc/health` (publishable key cukup) → antrean bus keluar per target + event terakhir per sumber.'
    : '`GET /auth/v1/health` (GoTrue).'), '');
  L.push(`## Baca: view (\`GET /rest/v1/<view>\`) — ${views.length}`, '', '| Endpoint | Boleh dibaca | Keterangan |', '|---|---|---|');
  for (const v of views) L.push(`| \`GET /rest/v1/${v.name}\` | ${who(v)} | ${doc[v.name] ?? ''} |`);
  L.push('', `## Aksi: RPC (\`POST /rest/v1/rpc/<fungsi>\`, body JSON = argumen) — ${fns.length}`, '',
    '| Endpoint | Argumen | Boleh dipanggil | Keterangan |', '|---|---|---|---|');
  for (const f of fns) L.push(`| \`POST /rest/v1/rpc/${f.name}\` | \`${f.args || '-'}\` | ${who(f)} | ${doc[f.name] ?? ''} |`);
  L.push('', `## Edge Function (\`/functions/v1/<nama>\`) — ${edge.length}`, '', '| Endpoint | Keterangan |', '|---|---|');
  for (const e of edge) L.push(`| \`/functions/v1/${e.name}\` | ${e.desc} |`);
  mkdirSync(join(ROOT, 'docs/endpoints'), { recursive: true });
  writeFileSync(join(ROOT, 'docs/endpoints', `${db.name}.md`), L.join('\n') + '\n');
  console.log(`docs/endpoints/${db.name}.md: ${views.length} view, ${fns.length} RPC, ${edge.length} Edge Function`);
}
