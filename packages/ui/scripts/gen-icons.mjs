// Generate src/icons.generated.ts from @material-symbols/svg-400 (Rounded, weight 400).
// Only a curated list is emitted so the bundle stays small (the full icon font is ~4 MB).
// Run: node packages/ui/scripts/gen-icons.mjs
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const pkgRoot = join(here, '..');
const require = createRequire(join(pkgRoot, 'package.json'));
const symbolsDir = join(dirname(require.resolve('@material-symbols/svg-400/package.json')), 'rounded');

/** Curated list, grouped like DS page 20 (Icon Library). */
const GROUPS = {
  navigation: [
    'home', 'campaign', 'task', 'checklist', 'account_balance_wallet', 'link', 'notifications', 'person', 'leaderboard',
    'group_add', 'settings', 'logout', 'login', 'menu', 'close', 'arrow_back', 'arrow_forward', 'arrow_upward',
    'arrow_downward', 'chevron_right', 'chevron_left', 'expand_more', 'keyboard_arrow_down', 'keyboard_arrow_up',
    'open_in_new', 'search', 'filter_list', 'sort', 'tune', 'unfold_more', 'more_vert', 'more_horiz', 'first_page',
    'last_page', 'explore', 'space_dashboard', 'dashboard', 'grid_view', 'list', 'admin_panel_settings', 'account_circle',
    'manage_accounts', 'history', 'arrow_outward',
  ],
  actions: [
    'add', 'remove', 'edit', 'delete', 'content_copy', 'download', 'upload', 'share', 'send', 'check', 'check_small',
    'check_circle', 'cancel', 'close_small', 'refresh', 'pause', 'play_arrow', 'push_pin', 'keep', 'flag', 'gavel',
    'block', 'undo', 'visibility', 'visibility_off', 'schedule', 'calendar_today', 'event', 'timer', 'bolt', 'lock',
    'verified', 'shield', 'info', 'warning', 'error', 'help', 'bookmark', 'add_link', 'link_off', 'progress_activity',
    'hourglass_top', 'star', 'person_add', 'support_agent', 'wifi_off', 'percent', 'tag', 'image', 'article',
    'description', 'add_circle',
  ],
  domain: [
    'play_circle', 'smartphone', 'mobile', 'movie', 'movie_edit', 'sports_esports', 'music_note', 'music_video', 'mic',
    'storefront', 'payments', 'account_balance', 'qr_code_2', 'receipt_long', 'redeem', 'diamond', 'card_giftcard',
    'trending_up', 'insights', 'monitoring', 'bar_chart', 'public', 'groups', 'badge', 'id_card', 'key', 'mail',
    'alternate_email', 'language', 'dark_mode', 'light_mode', 'contrast', 'install_mobile', 'mobile_arrow_down',
    'forum', 'local_fire_department', 'workspace_premium', 'photo_camera', 'smart_display',
  ],
};

/** Names from the brief that no longer exist in Material Symbols → the current glyph with the same meaning. */
const ALIASES = {
  expand_more: 'keyboard_arrow_down',
  push_pin: 'keep',
  smartphone: 'mobile',
  card_giftcard: 'redeem',
  insights: 'monitoring',
  install_mobile: 'mobile_arrow_down',
};

/**
 * Re-serialise path data with 1-decimal precision (< 0.01 px at 24 px on the 960-unit grid) and minimal separators.
 * Tokenised properly so that rounding never merges two numbers ("12.95.5" → "13 .5", "1-0.04" → "1 0").
 */
function compactPath(d) {
  const tokens = d.match(/[a-zA-Z]|-?(?:\d+\.?\d*|\.\d+)(?:e-?\d+)?/g) ?? [];
  let out = '';
  let prevNum = null;
  for (const t of tokens) {
    if (/[a-zA-Z]/.test(t)) {
      out += t;
      prevNum = null;
      continue;
    }
    let r = String(Math.round(Number(t) * 10) / 10);
    if (r.startsWith('0.')) r = r.slice(1);
    else if (r.startsWith('-0.')) r = `-${r.slice(2)}`;
    if (prevNum !== null && !r.startsWith('-') && !(r.startsWith('.') && prevNum.includes('.'))) out += ' ';
    out += r;
    prevNum = r;
  }
  return out;
}

const pathOf = (file) => {
  const svg = readFileSync(file, 'utf8');
  const viewBox = svg.match(/viewBox="([^"]+)"/)?.[1];
  const paths = [...svg.matchAll(/<path[^>]*\sd="([^"]+)"/g)].map((m) => compactPath(m[1]));
  if (!paths.length) throw new Error(`no <path> in ${file}`);
  return { viewBox, d: paths.join(' ') };
};

const names = [...new Set(Object.values(GROUPS).flat())];
const out = {};
const missing = [];
const aliased = {};
let viewBox;

for (const name of names) {
  const outline = join(symbolsDir, `${name}.svg`);
  if (!existsSync(outline)) {
    const target = ALIASES[name];
    if (target && existsSync(join(symbolsDir, `${target}.svg`))) aliased[name] = target;
    else missing.push(name);
    continue;
  }
  const o = pathOf(outline);
  viewBox ??= o.viewBox;
  if (o.viewBox !== viewBox) throw new Error(`unexpected viewBox ${o.viewBox} for ${name}`);
  const fillFile = join(symbolsDir, `${name}-fill.svg`);
  const f = existsSync(fillFile) ? pathOf(fillFile).d : undefined;
  out[name] = f && f !== o.d ? [o.d, f] : [o.d];
}
for (const [alias, target] of Object.entries(aliased)) {
  if (!out[target]) {
    const o = pathOf(join(symbolsDir, `${target}.svg`));
    const fillFile = join(symbolsDir, `${target}-fill.svg`);
    const f = existsSync(fillFile) ? pathOf(fillFile).d : undefined;
    out[target] = f && f !== o.d ? [o.d, f] : [o.d];
  }
}

const lines = [
  '// AUTO-GENERATED by scripts/gen-icons.mjs from @material-symbols/svg-400 (rounded). Do not edit by hand.',
  '// Each entry: [outlinePath, filledPath?]. viewBox is shared.',
  `export const ICON_VIEWBOX = ${JSON.stringify(viewBox)};`,
  '',
  'export const iconPaths = {',
  ...Object.keys(out)
    .sort()
    .map((n) => `  ${n}: ${JSON.stringify(out[n])},`),
  '} as const satisfies Record<string, readonly [string] | readonly [string, string]>;',
  '',
  '/** Old Material Icons names that were renamed in Material Symbols. */',
  'export const iconAliases = {',
  ...Object.entries(aliased).map(([a, t]) => `  ${a}: ${JSON.stringify(t)},`),
  '} as const satisfies Record<string, keyof typeof iconPaths>;',
  '',
  'export type IconName = keyof typeof iconPaths | keyof typeof iconAliases;',
  '',
];

writeFileSync(join(pkgRoot, 'src', 'icons.generated.ts'), lines.join('\n'));
console.log(`icons: ${Object.keys(out).length} glyphs, ${Object.keys(aliased).length} aliases`);
if (Object.keys(aliased).length) console.log(`renamed in Material Symbols (aliased): ${Object.entries(aliased).map(([a, t]) => `${a}→${t}`).join(', ')}`);
if (missing.length) console.log(`missing (skipped): ${missing.join(', ')}`);
