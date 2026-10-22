// Jalankan: pnpm e2e (butuh scripts/dev-stack.sh + 4 app di port 3000–3003, build produksi atau dev).
// Deploy self-hosted (deploy/deploy.sh): E2E_WEB/E2E_ACC/E2E_APP/E2E_BRAND, E2E_CORE_DB, E2E_MAILPIT menimpa default lokal;
// E2E_HOST_RULES = --host-resolver-rules Chromium (mis. "MAP auth.x 10.0.0.11") bila DNS host uji belum mengarah ke server.
// Journey lintas host: web → accounts (OTP Mailpit, onboarding + avatar) → app (kartu + brand, claim) → accounts/invite → brand.
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const fs = require('fs');
const OUT = require('path').join(__dirname, '..', 'test-results', 'e2e');
fs.mkdirSync(OUT, { recursive: true });
const env = (k, d) => process.env[k] || d;
const WEB = env('E2E_WEB', 'http://clipper.localhost:3000'), ACC = env('E2E_ACC', 'http://accounts.clipper.localhost:3001'),
  APP = env('E2E_APP', 'http://app.clipper.localhost:3002'), BRAND = env('E2E_BRAND', 'http://brand.clipper.localhost:3003');
const CORE_DB = env('E2E_CORE_DB', 'postgresql://postgres:postgres@127.0.0.1:55322/postgres');
const MAILPIT = env('E2E_MAILPIT', 'http://127.0.0.1:54324');
const BRAND_DB = env('E2E_BRAND_DB', 'postgresql://postgres:postgres@127.0.0.1:57322/postgres');
const sql = (q, db = CORE_DB) => execFileSync('psql', [db, '-X', '-tAqc', q], { encoding: 'utf8' }).trim();
const email = `e2e-${Date.now()}@clipper.localhost`;
const username = `e2e_${Date.now().toString(36)}`;
const SUBMIT_BRAND = 'Simpan & lanjut';
const log = (...a) => console.log('✓', ...a);

async function otp(addr, since) {
  for (let i = 0; i < 40; i++) {
    const r = await fetch(`${MAILPIT}/api/v1/search?query=to:${encodeURIComponent(addr)}`).then((r) => r.json());
    const m = (r.messages || []).find((x) => new Date(x.Created).getTime() >= since - 2000);
    const code = m && /(\d{6})/.exec(m.Subject + ' ' + (m.Snippet || ''))?.[1];
    if (code) return code;
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error('OTP tidak datang');
}

(async () => {
  const browser = await chromium.launch(
    process.env.E2E_HOST_RULES ? { args: [`--host-resolver-rules=${process.env.E2E_HOST_RULES}`] } : {},
  );
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'id-ID' });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(`pageerror ${page.url()}: ${e.message}`));
  page.on('console', (m) => m.type() === 'error' && errors.push(`console ${page.url()}: ${m.text()}`));
  const shot = (n) => page.screenshot({ path: `${OUT}/${n}.png`, fullPage: true });
  try {
    // 1. Landing publik: campaign seed tampil dengan nama brand (list_campaigns anon)
    await page.goto(WEB + '/');
    await page.getByRole('link', { name: /Ambil campaign/ }).first().waitFor({ timeout: 20000 });
    log('web: landing menampilkan kartu campaign');
    await shot('01-web');
    // 2. /c/[slug] publik: judul + nama brand (list_campaigns slug, anon)
    await page.goto(WEB + '/c/e2e-journey');
    await page.getByRole('heading', { name: 'E2E Journey Campaign' }).waitFor();
    await page.getByText('E2E Studio').first().waitFor();
    log('web: /c/e2e-journey + nama brand');
    await shot('01b-web-c');
    // 3. Login dari web → accounts (OTP)
    await page.goto(`${ACC}/login?next=${encodeURIComponent(APP + '/campaigns')}`);
    const since = Date.now();
    await page.getByLabel('Email').fill(email);
    await page.getByRole('button', { name: 'Kirim kode' }).click();
    const code = await otp(email, since);
    await page.getByLabel('Kode verifikasi').fill(code);
    await page.getByRole('button', { name: 'Masuk' }).click();
    await page.waitForURL(/\/onboarding/, { timeout: 20000 });
    log('accounts: OTP → onboarding');
    // 4. Onboarding: avatar + username + consent
    fs.writeFileSync(OUT + '/a.png', Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64'));
    const u = page.getByLabel('Username');
    await u.fill(username);
    await page.getByText('Username tersedia').waitFor({ timeout: 10000 }); // bukti sudah hydrate
    await page.locator('input[type=file]').setInputFiles(OUT + '/a.png');
    await page.getByRole('button', { name: 'Ganti foto' }).waitFor();
    await page.getByLabel('Nama tampilan').fill('E2E Clipper');
    for (const cb of await page.getByRole('checkbox').all()) await cb.check();
    await shot('02-onboarding');
    await page.getByRole('button', { name: 'Simpan & mulai' }).click();
    await page.waitForURL(APP + '/campaigns**', { timeout: 30000 });
    log('accounts → app: onboarding selesai, sesi SSO terbawa ke app');
    const avatar = sql(`select avatar_path from market.profiles where username = '${username}'`);
    if (!avatar) throw new Error('avatar_path kosong');
    log('core: profil + avatar', avatar);
    // 5. App: kartu dengan brand; hubungkan akun (seed) lalu claim
    await page.getByText('E2E Journey Campaign').first().waitFor({ timeout: 20000 });
    await shot('03-app-campaigns');
    const uid = sql(`select id from market.profiles where username = '${username}'`);
    sql(`insert into tracking.social_accounts (user_id, platform, external_id, handle, followers, platform_created_at)
         values ('${uid}', 'tiktok', 'tt-${username}', '@${username}', 5000, now() - interval '400 days')`);
    await page.goto(APP + '/campaigns/e2e00000-0000-0000-0000-0000000000c0');
    await page.getByText('E2E Studio').first().waitFor();
    await page.getByRole('button', { name: /^(Ambil|Claim)/ }).first().click();
    await page.waitForTimeout(1500);
    const claims = sql(`select count(*) from market.claims where user_id = '${uid}' and campaign_id = 'e2e00000-0000-0000-0000-0000000000c0'`);
    if (claims !== '1') throw new Error('claim tidak tercatat: ' + claims);
    log('app: claim campaign tercatat di core');
    await shot('04-app-claimed');
    await page.goto(APP + '/tasks');
    await page.getByText('E2E Journey Campaign').first().waitFor();
    log('app: /tasks menampilkan claim');
    // 5b. Share target PWA: link dari share sheet app sosmed → pilih claim → sheet Submit terbuka, link terisi
    const shared = 'https://www.tiktok.com/@' + username + '/video/7392000000000000001';
    const manifest = await page.evaluate(() => fetch('/manifest.webmanifest').then((r) => r.json()));
    if (manifest.share_target?.action !== '/share') throw new Error('manifest tanpa share_target');
    await page.goto(`${APP}/share?text=${encodeURIComponent('Clip baru ' + shared + ' cek!')}`);
    await page.getByRole('link', { name: 'Kirim ke campaign ini' }).first().click();
    await page.waitForURL(/\/campaigns\/e2e00000-0000-0000-0000-0000000000c0\?submit=1&url=/);
    const field = page.locator('input[type=url]');
    await field.waitFor({ timeout: 15000 });
    if ((await field.inputValue()) !== shared) throw new Error('link share tidak terisi: ' + (await field.inputValue()));
    log('app: share target → sheet Submit dengan link terisi');
    await shot('04b-app-share-submit');
    // 6. Undangan tim brand: preview org + role → terima → brand
    const tok = 'e2eTok' + Date.now().toString(36) + 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
    sql(`insert into market.org_invites (org_id, role, token_hash, expires_at, created_by)
         values ('e2e00000-0000-0000-0000-0000000000a0', 'brand_viewer', sha256(convert_to('${tok}', 'UTF8')), now() + interval '7 days',
                 'e2e00000-0000-0000-0000-0000000000b0')`, BRAND_DB);
    await page.goto(`${ACC}/invite/${tok}`);
    await page.getByText('E2E Studio').first().waitFor();
    log('accounts: preview undangan menampilkan org');
    if (await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth)) {
      throw new Error('halaman undangan melebar horizontal di 390px');
    }
    await shot('05-invite');
    await page.getByRole('button', { name: 'Terima undangan' }).click();
    // Peran baru (brand) butuh consent ToS brand: onboarding role=brand (profil sudah ada) lalu kembali ke brand.
    await page.waitForURL(/onboarding\?role=brand/, { timeout: 30000 });
    await page.getByText('Username tersedia').waitFor({ timeout: 15000 }); // bukti sudah hydrate
    for (const cb of await page.getByRole('checkbox').all()) await cb.check();
    await shot('05b-onboarding-brand');
    await page.getByRole('button', { name: SUBMIT_BRAND }).click();
    await page.waitForURL(BRAND + '/**', { timeout: 30000 });
    await page.getByText('E2E Studio').first().waitFor({ timeout: 20000 });
    log('brand: anggota baru melihat org', page.url());
    await shot('06-brand');
  } catch (e) {
    await shot('99-fail').catch(() => {});
    console.error('✗', e.message, '@', page.url());
    process.exitCode = 1;
  } finally {
    const relevant = errors.filter((e) => !/favicon|Download the React DevTools/.test(e));
    if (relevant.length) console.log('Console/page errors:\n' + relevant.join('\n'));
    await browser.close();
  }
})();
