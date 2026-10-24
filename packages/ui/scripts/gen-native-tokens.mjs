// Token DS (src/styles.css) → apps/mobile/src/tokens.gen.ts: warna light (@theme static semantik) & dark (.dark), radius.
// Satu sumber untuk web & app native; tes apps/mobile/src/tokens.test.ts gagal kalau generator belum dijalankan ulang.
// Pakai: node packages/ui/scripts/gen-native-tokens.mjs [--check]
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, '../src/styles.css'), 'utf8');
const out = join(here, '../../../apps/mobile/src/tokens.gen.ts');

/** Isi blok kurawal yang dibuka pertama kali sesudah posisi `from`. */
function blockAt(from) {
  const open = css.indexOf('{', from);
  let depth = 0;
  for (let j = open; j < css.length; j++) {
    if (css[j] === '{') depth++;
    else if (css[j] === '}' && --depth === 0) return css.slice(open + 1, j);
  }
  throw new Error(`blok tidak tertutup di ${from}`);
}

const camel = (s) => s.replace(/-([a-z0-9])/g, (_, c) => c.toUpperCase());
// rgb(29 91 255 / 0.18) → rgba(29,91,255,0.18): parser warna React Native tidak selalu kenal sintaks spasi.
const rn = (v) => v.replace(/rgb\((\d+) (\d+) (\d+) \/ ([\d.]+)\)/g, 'rgba($1,$2,$3,$4)');
function vars(body, prefix) {
  const res = {};
  for (const m of body.matchAll(new RegExp(`--${prefix}-([a-z0-9-]+):\\s*([^;]+);`, 'g'))) res[camel(m[1])] = rn(m[2].trim());
  return res;
}

const themes = [...css.matchAll(/@theme static \{/g)].map((m) => m.index);
if (themes.length < 2) throw new Error('@theme static semantik tidak ditemukan');
const brand = blockAt(themes[0]); // palet brand + radius
const semantic = blockAt(themes[1]); // token semantik mode terang
const dark = blockAt(css.search(/^\s*\.dark,\s*$/m)); // blok token dark (bukan @custom-variant yang juga menyebut .dark)
const navy = vars(brand, 'color').navy;

// Tipografi: ukuran fluid clamp(min, …) → nilai min (layar HP), rem×16 → px; line-height & tracking jadi px (RN).
const px = (v) => {
  const first = v.startsWith('clamp(') ? v.slice(6).split(',')[0].trim() : v;
  return Math.round(Number.parseFloat(first) * (first.endsWith('rem') ? 16 : 1) * 100) / 100;
};
const text = {};
for (const m of brand.matchAll(/--text-([a-z0-9-]+?):\s*([^;]+);/g)) {
  if (m[1].includes('--')) continue;
  const size = px(m[2].trim());
  const get = (suffix) => brand.match(new RegExp(`--text-${m[1]}--${suffix}:\\s*([^;]+);`))?.[1].trim();
  const lh = get('line-height');
  const ls = get('letter-spacing');
  const fw = get('font-weight');
  text[camel(m[1])] = {
    fontSize: size,
    ...(lh ? { lineHeight: Math.round(size * Number.parseFloat(lh)) } : {}),
    ...(ls ? { letterSpacing: Math.round(size * Number.parseFloat(ls) * 100) / 100 } : {}),
    ...(fw ? { fontWeight: fw } : {}),
  };
}

const tokens = {
  light: { navy, ...vars(semantic, 'color') },
  dark: { navy, ...vars(dark, 'color') },
  radius: Object.fromEntries(Object.entries(vars(brand, 'radius')).map(([k, v]) => [k, Number.parseFloat(v)])),
  text,
};

const src = `// AUTO-GENERATED oleh packages/ui/scripts/gen-native-tokens.mjs dari packages/ui/src/styles.css. Jangan edit manual.
export const tokens = ${JSON.stringify(tokens, null, 2)} as const;
`;
if (process.argv.includes('--check')) {
  if (readFileSync(out, 'utf8') !== src) {
    console.error('tokens.gen.ts basi: jalankan node packages/ui/scripts/gen-native-tokens.mjs');
    process.exit(1);
  }
} else {
  writeFileSync(out, src);
}
