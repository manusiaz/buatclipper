// Invarian arsitektur yang dicek statis (KNOWLEDGE_GRAPH "Invarian pemisahan" 1, 4 + §15.3): arah import, jalur ke data
// identity, secret di app Next.js, dan HTML mentah (R-16). Dipanggil `pnpm lint`.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const errors = [];

function* walk(dir) {
  for (const name of readdirSync(dir)) {
    if (['node_modules', '.next', 'dist', 'coverage'].includes(name)) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* walk(p);
    else if (/\.(ts|tsx|mjs|js)$/.test(name)) yield p;
  }
}

const SECRET = /\b(SUPABASE_SERVICE_ROLE_KEY|SUPABASE_SECRET_KEYS?|PII_[A-Z_]+|BRIDGE_SECRET_[A-Z_]+|RESEND_API_KEY|[A-Z]+_CLIENT_SECRET|[A-Z]+_APP_SECRET|XENDIT_[A-Z_]+|VAPID_PRIVATE_KEY|DISBURSE_CALLBACK_TOKEN|UNSUBSCRIBE_SECRET)\b/;
const NO_IDENTITY = ['web', 'brand'];

for (const app of readdirSync(join(root, 'apps'))) {
  const pkg = JSON.parse(readFileSync(join(root, 'apps', app, 'package.json'), 'utf8'));
  if (NO_IDENTITY.includes(app) && pkg.dependencies?.['@clipper/db-identity']) {
    errors.push(`apps/${app}/package.json: tidak boleh bergantung ke @clipper/db-identity (invarian 1)`);
  }
  for (const file of walk(join(root, 'apps', app))) {
    const src = readFileSync(file, 'utf8');
    const rel = relative(root, file);
    if (/from ['"]@clipper\/app-/.test(src) || /from ['"](\.\.\/)+apps\//.test(src)) errors.push(`${rel}: app tidak boleh import app lain`);
    if (NO_IDENTITY.includes(app) && /@clipper\/db-identity|identityApi\(|identityFunctionUrl\(/.test(src)) {
      errors.push(`${rel}: ${app} tidak punya jalur ke data identity (invarian 1)`);
    }
    if (SECRET.test(src)) errors.push(`${rel}: app Next.js tidak boleh membaca secret (${src.match(SECRET)[0]}) (invarian 4)`);
    if (/dangerouslySetInnerHTML/.test(src) && !/\/\/ allow-inner-html: /.test(src)) {
      errors.push(`${rel}: dangerouslySetInnerHTML dilarang (R-16); tandai '// allow-inner-html: <alasan>' kalau memang data statis`);
    }
    if (/rehype-raw|allowDangerousHtml/.test(src)) errors.push(`${rel}: Markdown brief tidak boleh merender HTML mentah (R-16)`);
  }
}
for (const file of walk(join(root, 'packages'))) {
  const src = readFileSync(file, 'utf8');
  if (/from ['"]@clipper\/app-/.test(src)) errors.push(`${relative(root, file)}: package tidak boleh import app`);
  if (SECRET.test(src) && !file.includes('/scripts/')) errors.push(`${relative(root, file)}: package app tidak boleh membaca secret`);
}

if (errors.length) {
  console.error(errors.join('\n'));
  process.exit(1);
}
console.log('check-arch: ok');
