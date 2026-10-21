// Jalankan: pnpm e2e:mobile (butuh scripts/dev-stack.sh, e2e/seed.sql, accounts di :3001, dan build web app native
// `pnpm --filter @clipper/mobile export:web`). Build web app native disajikan di host app (:3002) supaya origin-nya lolos
// CORS Edge Function; kode layarnya sama dengan build Android/iOS (beda hanya modul .web stub: push, widget, share intent).
// Journey: login OTP native → gate onboarding → onboarding di accounts → tab Campaign → claim → Tugas → share → Wallet
// → tema gelap → keluar.
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const fs = require('fs');
const http = require('http');
const path = require('path');
const OUT = path.join(__dirname, '..', 'test-results', 'e2e-mobile');
const DIST = path.join(__dirname, '..', 'apps', 'mobile', 'dist');
fs.mkdirSync(OUT, { recursive: true });
const NATIVE = 'http://app.clipper.localhost:3002', ACC = 'http://accounts.clipper.localhost:3001';
const CORE_DB = 'postgresql://postgres:postgres@127.0.0.1:55322/postgres', MAILPIT = 'http://127.0.0.1:54324';
const CAMPAIGN = 'e2e00000-0000-0000-0000-0000000000c0';
const sql = (q) => execFileSync('psql', [CORE_DB, '-X', '-tAqc', q], { encoding: 'utf8' }).trim();
const email = `m2e-${Date.now()}@clipper.localhost`;
const username = `m2e_${Date.now().toString(36)}`;
const log = (...a) => console.log('✓', ...a);

const inbox = (addr) => fetch(`${MAILPIT}/api/v1/search?query=to:${encodeURIComponent(addr)}`).then((r) => r.json()).then((r) => r.messages || []);

// Email OTP baru (bukan yang sudah ada sebelum kirim kode — login native & accounts memakai email yang sama).
async function otp(addr, seen) {
  for (let i = 0; i < 40; i++) {
    const m = (await inbox(addr)).find((x) => !seen.has(x.ID));
    const code = m && /(\d{6})/.exec(m.Subject + ' ' + (m.Snippet || ''))?.[1];
    if (code) return code;
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error('OTP tidak datang');
}

async function signIn(page, label) {
  const seen = new Set((await inbox(email)).map((m) => m.ID));
  await page.getByLabel('Email').fill(email);
  await page.getByRole('button', { name: 'Kirim kode' }).click();
  await page.getByLabel('Kode verifikasi').fill(await otp(email, seen));
  await page.getByRole('button', { name: 'Masuk', exact: true }).click();
  log(label, 'OTP terkirim & diverifikasi');
}

// Server statis SPA untuk dist (file ada → kirim, selain itu index.html = routing expo-router di klien).
const types = { '.js': 'text/javascript', '.html': 'text/html', '.json': 'application/json', '.png': 'image/png', '.ttf': 'font/ttf', '.ico': 'image/x-icon' };
const server = http.createServer((req, res) => {
  const p = path.join(DIST, decodeURIComponent(req.url.split('?')[0]));
  const file = p.startsWith(DIST) && fs.existsSync(p) && fs.statSync(p).isFile() ? p : path.join(DIST, 'index.html');
  res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});

(async () => {
  if (!fs.existsSync(path.join(DIST, 'index.html'))) throw new Error('build web belum ada: pnpm --filter @clipper/mobile export:web');
  await new Promise((ok) => server.listen(3002, ok));
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, locale: 'id-ID' });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(`pageerror ${page.url()}: ${e.message}`));
  page.on('console', (m) => m.type() === 'error' && errors.push(`console ${page.url()}: ${m.text()}`));
  const shot = (n) => page.screenshot({ path: `${OUT}/${n}.png` });
  try {
    // 1. Tanpa sesi → layar login native; OTP → akun baru belum consent → gate onboarding (bukan tab)
    await page.goto(NATIVE + '/');
    await page.getByRole('heading', { name: 'Masuk ke Clipper' }).waitFor({ timeout: 30000 });
    await shot('01-login');
    await signIn(page, 'native:');
    await page.getByText('Lengkapi profilmu dulu').waitFor({ timeout: 20000 });
    await page.getByRole('button', { name: 'Sudah, lanjutkan' }).click();
    await page.getByText('Profil belum lengkap').waitFor();
    log('native: gate onboarding menahan akun tanpa consent');
    await shot('02-onboarding-gate');
    // 2. Onboarding di accounts (browser sistem di HP) → kembali → refresh token → claim consent → tab Campaign
    const web = await ctx.newPage();
    await web.goto(`${ACC}/onboarding`); // = tombol "Buka halaman akun" di app (openWeb accounts /onboarding)
    await signIn(web, 'accounts:');
    await web.waitForURL(/\/onboarding/, { timeout: 20000 }).catch(async (e) => (await web.screenshot({ path: `${OUT}/99-web.png` }), Promise.reject(e)));
    await web.getByLabel('Username').fill(username);
    await web.getByText('Username tersedia').waitFor({ timeout: 10000 });
    await web.getByLabel('Nama tampilan').fill('M2E Clipper');
    for (const cb of await web.getByRole('checkbox').all()) await cb.check();
    await web.getByRole('button', { name: 'Simpan & mulai' }).click();
    await web.waitForURL((u) => !u.pathname.startsWith('/onboarding'), { timeout: 30000 });
    await web.close();
    await page.getByRole('button', { name: 'Sudah, lanjutkan' }).click();
    await page.getByText('E2E Journey Campaign').first().waitFor({ timeout: 20000 });
    log('native: onboarding selesai → tab Campaign menampilkan campaign seed');
    await shot('03-campaigns');
    // 3. Detail → claim (RPC claim_campaign dengan JWT identity) → tercatat di core
    const uid = sql(`select id from market.profiles where username = '${username}'`);
    sql(`insert into tracking.social_accounts (user_id, platform, external_id, handle, followers, platform_created_at)
         values ('${uid}', 'tiktok', 'tt-${username}', '@${username}', 5000, now() - interval '400 days')`);
    await page.getByRole('link', { name: 'E2E Journey Campaign' }).first().click();
    await page.getByTestId('claim').click({ timeout: 15000 });
    await page.getByTestId('open-submit').waitFor({ timeout: 15000 });
    const claims = sql(`select count(*) from market.claims where user_id = '${uid}' and campaign_id = '${CAMPAIGN}'`);
    if (claims !== '1') throw new Error('claim tidak tercatat: ' + claims);
    log('native: claim tercatat di core, CTA berubah jadi Submit');
    await shot('04-claimed');
    // 4. Tab Tugas menampilkan claim
    await page.goto(NATIVE + '/tasks');
    await page.getByText('E2E Journey Campaign').first().waitFor({ timeout: 15000 });
    log('native: Tugas menampilkan claim');
    await shot('05-tasks');
    // 5. Share sheet (Android SEND / iOS share extension → /share?url=) → pilih claim → Submit dengan link terisi
    const shared = 'https://www.tiktok.com/@' + username + '/video/7392000000000000001';
    await page.goto(`${NATIVE}/share?url=${encodeURIComponent(shared)}`);
    await page.getByRole('button', { name: 'Kirim ke campaign ini' }).first().click();
    const field = page.getByLabel('URL video');
    await field.waitFor({ timeout: 15000 });
    if ((await field.inputValue()) !== shared) throw new Error('link share tidak terisi: ' + (await field.inputValue()));
    log('native: share → Submit dengan link terisi');
    await shot('06-share-submit');
    // 6. Wallet: saldo Rp dari core, tarik saldo diarahkan ke web
    await page.goto(NATIVE + '/wallet');
    await page.getByText('Saldo tersedia').first().waitFor({ timeout: 15000 });
    log('native: Wallet tampil');
    await shot('07-wallet');
    // 7. Akun: tema gelap dari token DS (.dark)
    await page.goto(NATIVE + '/account');
    await page.getByText('Gelap', { exact: true }).click();
    await page.waitForTimeout(500);
    await shot('08-account-dark');
    log('native: tema gelap');
    // 8. Keluar: push perangkat dilepas lalu sesi lokal dihapus → kembali ke login
    await page.getByRole('button', { name: 'Keluar' }).last().click();
    await page.getByRole('heading', { name: 'Masuk ke Clipper' }).waitFor({ timeout: 15000 });
    log('native: keluar → layar login');
  } catch (e) {
    await shot('99-fail').catch(() => {});
    console.error('✗', e.message, '@', page.url());
    process.exitCode = 1;
  } finally {
    // Submit memanggil list_videos ke API TikTok; akun seed tanpa token OAuth → 500 (sandbox juga tanpa internet).
    const relevant = errors.filter((e) => !/favicon|Download the React DevTools/.test(e) && !/\/submit\?.*status of 500/.test(e));
    if (relevant.length) console.log('Console/page errors:\n' + relevant.join('\n'));
    await browser.close();
    server.close();
  }
})();
