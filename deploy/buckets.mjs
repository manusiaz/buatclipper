// [storage.buckets.*] di db/<p>/supabase/config.toml (sumber kebenaran, dipakai CLI lokal) → SQL upsert storage.buckets
// untuk stack self-hosted. Format blok di config.toml: public, file_size_limit ("NMiB"/"NKiB"), allowed_mime_types.
import fs from 'node:fs';

const toml = fs.readFileSync(process.argv[2], 'utf8');
const units = { B: 1, KiB: 1024, MiB: 1024 ** 2, GiB: 1024 ** 3 };
const q = (s) => `'${String(s).replaceAll("'", "''")}'`;
const rows = [];
for (const m of toml.matchAll(/^\[storage\.buckets\.([a-z0-9-]+)\]\n((?:(?!\[)[^\n]*\n?)*)/gm)) {
  const body = m[2];
  const pub = /^public\s*=\s*true/m.test(body);
  const size = /^file_size_limit\s*=\s*"(\d+)(B|KiB|MiB|GiB)"/m.exec(body);
  const mimes = /^allowed_mime_types\s*=\s*\[([^\]]*)\]/m.exec(body);
  const list = mimes ? [...mimes[1].matchAll(/"([^"]+)"/g)].map((x) => q(x[1])) : [];
  rows.push(`(${q(m[1])}, ${q(m[1])}, ${pub}, ${size ? Number(size[1]) * units[size[2]] : 'null'}, ` +
    `${list.length ? `array[${list.join(', ')}]` : 'null'})`);
}
if (!rows.length) process.exit(0);
console.log(`insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ${rows.join(',\n  ')}
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;`);
