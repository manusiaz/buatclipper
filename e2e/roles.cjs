// Jalankan: node e2e/roles.cjs (butuh scripts/dev-stack.sh + 5 app: web :3000, accounts :3001, app :3002, brand :3003, admin :3004).
// Journey lintas role lewat UI asli: brand daftar → org → admin (OTP + TOTP) verifikasi org → builder campaign 7 langkah (cover,
// aset, rule, pool) → ajukan → invoice → admin konfirmasi bayar → admin approve → tayang (web + app) → clipper daftar → claim →
// submisi → brand review (approve + reject) → banding → admin putus → snapshot views → pending → release → KYC + rekening →
// withdraw → brand lihat spend.
// Yang tidak bisa offline dijalankan lewat fungsi SQL yang sama dengan Edge Function/job (lihat komentar "SIMULASI").
// ROLES_FROM=<nama langkah> melanjutkan dari langkah itu memakai state + sesi tersimpan di test-results/e2e-roles/.
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const OUT = path.join(__dirname, '..', 'test-results', 'e2e-roles');
fs.mkdirSync(OUT, { recursive: true });
const env = (k, d) => process.env[k] || d;
const WEB = env('E2E_WEB', 'http://clipper.localhost:3000'), ACC = env('E2E_ACC', 'http://accounts.clipper.localhost:3001'),
  APP = env('E2E_APP', 'http://app.clipper.localhost:3002'), BRAND = env('E2E_BRAND', 'http://brand.clipper.localhost:3003'),
  ADMIN = env('E2E_ADMIN', 'http://admin.clipper.localhost:3004');
const CORE_DB = env('E2E_CORE_DB', 'postgresql://postgres:postgres@127.0.0.1:55322/postgres');
const BRAND_DB = env('E2E_BRAND_DB', 'postgresql://postgres:postgres@127.0.0.1:57322/postgres');
const ID_DB = env('E2E_IDENTITY_DB', 'postgresql://postgres:postgres@127.0.0.1:54322/postgres');
const MAILPIT = env('E2E_MAILPIT', 'http://127.0.0.1:54324');
const psql = (db, q) => execFileSync('psql', [db, '-X', '-v', 'ON_ERROR_STOP=1', '-tAqc', q], { encoding: 'utf8' }).trim();
const core = (q) => psql(CORE_DB, q);
const brandDb = (q) => psql(BRAND_DB, q);
const CREATOR_DB = env('E2E_CREATOR_DB', 'postgresql://postgres:postgres@127.0.0.1:56322/postgres');
/** Bus antar DB tidak macet: tidak ada event gagal yang belum terkirim di outbox ketiga project. */
const busStuck = () =>
  [['admin', CORE_DB], ['brand', BRAND_DB], ['creator', CREATOR_DB]]
    .map(([n, db]) => [n, psql(db, `select coalesce(string_agg(target || ': ' || left(last_error, 80), '; '), '') from bus.outbox where sent_at is null and last_error is not null`)])
    .filter(([, e]) => e)
    .map(([n, e]) => `${n} → ${e}`)
    .join(' | ');
/** Replika lewat bus (relay tiap detik): tunggu sampai query admin menghasilkan nilai yang sama dengan pemilik data. */
const replicated = async (q, want, ms = 20000, db = CORE_DB) => {
  let got = '';
  for (const end = Date.now() + ms; Date.now() < end; await new Promise((r) => setTimeout(r, 500))) if ((got = psql(db, q)) === want) break;
  return got;
};
const ident = (q) => psql(ID_DB, q);
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`;
const log = (...a) => console.log('✓', ...a);
const note = (...a) => console.log('•', ...a);
const STATE = path.join(OUT, 'state.json');
const findings = [];
const finding = (msg) => (findings.push(msg), console.log('! TEMUAN:', msg));
function check(cond, msg) {
  if (!cond) throw new Error('asersi gagal: ' + msg);
}

// ---------- email OTP (Mailpit) ----------
const inbox = (addr) =>
  fetch(`${MAILPIT}/api/v1/search?query=to:${encodeURIComponent(addr)}`).then((r) => r.json()).then((r) => r.messages || []);
async function otp(addr, seen) {
  for (let i = 0; i < 40; i++) {
    const m = (await inbox(addr)).find((x) => !seen.has(x.ID));
    const code = m && /(\d{6})/.exec(m.Subject + ' ' + (m.Snippet || ''))?.[1];
    if (code) return code;
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error('OTP tidak datang ke ' + addr);
}
async function signIn(page, addr) {
  const seen = new Set((await inbox(addr)).map((m) => m.ID));
  await page.getByLabel('Email').fill(addr);
  await page.getByRole('button', { name: 'Kirim kode' }).click();
  await page.getByLabel('Kode verifikasi').fill(await otp(addr, seen));
  await page.getByRole('button', { name: 'Masuk', exact: true }).click();
}

// ---------- TOTP RFC 6238 (SHA-1, 30 dtk, 6 digit) ----------
function totp(secret, t = Date.now()) {
  const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = '';
  for (const c of secret.replace(/[\s=]/g, '').toUpperCase()) bits += abc.indexOf(c).toString(2).padStart(5, '0');
  const key = Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2)));
  const ctr = Buffer.alloc(8);
  ctr.writeBigUInt64BE(BigInt(Math.floor(t / 30000)));
  const h = crypto.createHmac('sha1', key).update(ctr).digest();
  const o = h[19] & 15;
  return String((h.readUInt32BE(o) & 0x7fffffff) % 1e6).padStart(6, '0');
}

// ---------- berkas uji ----------
const PNG = path.join(OUT, 'cover.png');
fs.writeFileSync(PNG, Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64'));
const PDF = path.join(OUT, 'brief.pdf');
fs.writeFileSync(PDF, '%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n');

const wibInput = (ms) => {
  const d = new Date(ms + 7 * 3600e3);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())}T${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`;
};
const digits = (s) => Number(String(s).replace(/\D/g, ''));

// ---------- state & sesi per role ----------
let S = {};
const stamp = Date.now().toString(36);
function freshState() {
  return {
    stamp,
    brandEmail: `roles-brand-${stamp}@clipper.localhost`,
    adminEmail: `roles-admin-${stamp}@clipper.localhost`,
    clipperEmail: `roles-clip-${stamp}@clipper.localhost`,
    brandUser: `rb_${stamp}`,
    clipperUser: `rc_${stamp}`,
    orgName: `QA Roles ${stamp}`,
    title: `QA Roles Campaign ${stamp}`,
    hashtag: `qaroles${stamp}`,
  };
}

const STEPS = [];
const step = (name, roles, fn) => STEPS.push({ name, roles, fn });
let shotN = 0;

// =============================== LANGKAH ===============================

step('brand-signup', ['brand'], async ({ brand }) => {
  // B1.1–B1.3: landing "Daftar sebagai brand" → accounts login (next=brand/new) → OTP → onboarding role=brand
  await brand.goto(WEB + '/');
  const cta = brand.getByRole('link', { name: /Daftar sebagai brand/i }).first();
  await cta.waitFor({ timeout: 30000 });
  const href = await cta.getAttribute('href');
  check(href && href.includes('accounts.') && decodeURIComponent(href).includes('brand.'), 'CTA brand ke accounts?next=brand: ' + href);
  await cta.click();
  await brand.waitForURL(/accounts\..*\/login/, { timeout: 30000 });
  await signIn(brand, S.brandEmail);
  await brand.waitForURL(/\/onboarding/, { timeout: 30000 });
  check(/role=brand/.test(brand.url()), 'onboarding role=brand: ' + brand.url());
  await brand.getByLabel('Username').fill(S.brandUser);
  await brand.getByText('Username tersedia').waitFor({ timeout: 15000 });
  await brand.getByLabel('Nama tampilan').fill('QA Brand Owner');
  for (const cb of await brand.getByRole('checkbox').all()) await cb.check();
  await shot(brand, 'brand-onboarding');
  await brand.getByRole('button', { name: 'Simpan & lanjut' }).click();
  await brand.waitForURL(BRAND + '/new**', { timeout: 30000 });
  S.brandId = core(`select id from market.profiles where username = ${lit(S.brandUser)}`);
  check(S.brandId, 'profil brand dibuat');
  const consents = ident(`select string_agg(kind::text, ',' order by kind) from member.consents where user_id = '${S.brandId}'`);
  check(/tos_brand/.test(consents) && /privacy/.test(consents), 'consent brand tercatat: ' + consents);
  log('brand: OTP + onboarding brand → brand/new; consent', consents);
});

step('brand-create-org', ['brand'], async ({ brand }) => {
  // B1.4: buat organisasi (badan usaha)
  if (!brand.url().startsWith(BRAND + '/new')) await brand.goto(BRAND + '/new');
  await brand.getByRole('textbox', { name: 'Nama brand' }).fill(S.orgName);
  await brand.getByRole('textbox', { name: 'Nama legal' }).fill('PT QA Roles Indonesia');
  await brand.getByRole('textbox', { name: 'NPWP' }).fill('01.234.567.8-901.000');
  await brand.getByRole('textbox', { name: 'Alamat' }).fill('Jl. Sudirman 1, Jakarta');
  await shot(brand, 'brand-new-org');
  await brand.getByRole('button', { name: 'Buat organisasi' }).click();
  await brand.waitForURL((u) => u.href.startsWith(BRAND + '/') && !u.pathname.startsWith('/new'), { timeout: 30000 });
  const orgQ = `select o.id || '|' || o.status || '|' || m.role from market.organizations o join market.org_members m on m.org_id = o.id
                where o.name = ${lit(S.orgName)} and m.user_id = '${S.brandId}'`;
  const row = brandDb(orgQ);
  const [orgId, status, role] = row.split('|');
  check(status === 'pending_verification' && role === 'brand_owner', 'org pending + brand_owner (DB brand): ' + row);
  check((await replicated(orgQ, row)) === row, 'org + pemilik tereplika ke admin');
  S.orgId = orgId;
  S.orgSlug = new URL(brand.url()).pathname.split('/')[1];
  await brand.getByText(/Menunggu verifikasi/i).first().waitFor({ timeout: 15000 });
  await shot(brand, 'brand-org-pending');
  log('brand: org dibuat', S.orgSlug, status);
});

step('admin-login', ['admin'], async ({ admin }) => {
  // J-A1: akun admin terpisah. Bootstrap persis `deploy/deploy.sh admin`: Admin API GoTrue dipanggil dari Postgres (pg_net) dengan
  // service key yang sudah di Vault identity (kunci tidak keluar dari DB), lalu role admin_super + audit log lewat SQL.
  S.adminEmail = `roles-admin-${Date.now().toString(36)}@clipper.localhost`; // selalu akun baru (re-run aman)
  await admin.context().clearCookies();
  const rid = ident(`select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'identity_url') || '/auth/v1/admin/users',
      headers := jsonb_build_object('Authorization', 'Bearer ' || k.v, 'apikey', k.v, 'Content-Type', 'application/json'),
      body := jsonb_build_object('email', ${lit(S.adminEmail)}, 'email_confirm', true))
    from (select decrypted_secret as v from vault.decrypted_secrets where name = 'identity_secret_key') k`);
  let code = '';
  for (let i = 0; i < 30 && !code; i++) {
    code = ident(`select coalesce(status_code::text, '') from net._http_response where id = ${rid}`);
    if (!code) await admin.waitForTimeout(500);
  }
  check(/^2/.test(code), 'Admin API GoTrue membuat user admin: ' + code);
  const uid = ident(`select id from auth.users where email = ${lit(S.adminEmail)}`);
  check(uid, 'auth.users admin dibuat');
  ident(`with g as (insert into member.platform_roles (user_id, role) values ('${uid}', 'admin_super') on conflict do nothing returning user_id)
         insert into member.audit_logs (actor_id, action, target, after)
         select null, 'role.grant', 'user:' || user_id, '{"role":"admin_super","via":"e2e/roles.cjs"}' from g`);
  S.adminId = uid;
  await admin.goto(ADMIN + '/login');
  await signIn(admin, S.adminEmail);
  // Login pertama: daftar TOTP (QR + kunci manual)
  await admin.getByText('Aktifkan aplikasi authenticator').waitFor({ timeout: 30000 });
  const secretField = admin.getByLabel('Atau masukkan kunci ini manual');
  await secretField.waitFor({ timeout: 20000 });
  const secret = (await secretField.inputValue()).trim();
  check(/^[A-Z2-7]{16,}$/.test(secret), 'kunci TOTP terbaca: ' + secret);
  S.totpSecret = secret;
  await shot(admin, 'admin-mfa-enroll');
  // Kode di awal jendela 30 dtk (hindari kode yang kedaluwarsa di tengah request), coba ulang sekali dengan kode jendela berikutnya.
  for (let attempt = 0; ; attempt++) {
    if (Date.now() % 30000 > 24000) await admin.waitForTimeout(30500 - (Date.now() % 30000));
    await admin.getByLabel('Kode authenticator').fill(totp(secret));
    await admin.getByRole('button', { name: 'Verifikasi' }).click();
    const ok = await admin.waitForURL(ADMIN + '/', { timeout: 15000 }).then(() => true, () => false);
    if (ok) break;
    check(attempt < 1, 'TOTP ditolak dua kali');
    finding('admin MFA: kode TOTP valid ditolak sekali ("Kode authenticator salah.") — dicoba ulang');
    await admin.waitForTimeout(30500 - (Date.now() % 30000));
  }
  await admin.getByRole('heading', { name: /Overview/i }).first().waitFor({ timeout: 30000 });
  const factor = ident(`select status from auth.mfa_factors where user_id = '${uid}'`);
  check(factor === 'verified', 'faktor TOTP verified: ' + factor);
  await shot(admin, 'admin-overview');
  log('admin: OTP + TOTP enroll → overview (aal2)');
});

step('admin-verify-org', ['admin', 'brand'], async ({ admin, brand }) => {
  // B1.5 / A2.2
  await admin.goto(`${ADMIN}/users?tab=org&org=${S.orgId}`);
  await admin.getByText(S.orgName).first().waitFor({ timeout: 30000 });
  await admin.getByRole('button', { name: 'Verifikasi' }).first().click();
  const dlg = admin.getByRole('dialog');
  await dlg.waitFor();
  await shot(admin, 'admin-verify-org-dialog');
  await dlg.getByRole('button', { name: 'Verifikasi' }).click();
  await dlg.waitFor({ state: 'detached', timeout: 20000 });
  const st = brandDb(`select status from market.organizations where id = '${S.orgId}'`);
  check(st === 'verified', 'org verified (DB brand): ' + st);
  const rep = await replicated(`select o.status || '|' || (select count(*) from trust.review_decisions d where d.target_type = 'org' and d.target_id = o.id)
                                  from market.organizations o where o.id = '${S.orgId}'`, 'verified|1');
  check(rep === 'verified|1', 'status + keputusan review tereplika ke admin: ' + rep);
  const creatorOrg = await replicated(`select status from market.organizations where id = '${S.orgId}'`, 'verified', 20000, CREATOR_DB);
  check(creatorOrg === 'verified', 'replika org di creator: ' + creatorOrg);
  const stuck = busStuck();
  check(!stuck, 'bus antar DB tidak macet: ' + stuck);
  await shot(admin, 'admin-org-verified');
  await brand.goto(`${BRAND}/${S.orgSlug}/campaigns`);
  await brand.waitForLoadState('networkidle');
  check(!(await brand.getByText(/Menunggu verifikasi/i).count()), 'banner Menunggu verifikasi hilang di brand');
  log('admin: org diverifikasi; banner brand hilang');
});

step('brand-builder', ['brand'], async ({ brand }) => {
  // B1.6: builder 7 langkah (judul baru tiap percobaan supaya draft percobaan gagal tidak tertukar)
  S.title = `QA Roles Campaign ${Date.now().toString(36)}`;
  await brand.goto(`${BRAND}/${S.orgSlug}/campaigns/new`);
  const next = () => brand.getByRole('navigation', { name: 'Navigasi langkah' }).getByRole('button', { name: /Lanjut|Lihat ringkasan/ }).click();
  const heading = (t) => brand.locator('#cb-step-heading', { hasText: t }).waitFor({ timeout: 15000 });
  // 1 Dasar + cover
  await heading('Dasar');
  await brand.getByLabel(/Nama campaign/).fill(S.title);
  await brand.locator('input[type=file]').first().setInputFiles(PNG);
  await brand.getByText(/cover\.png terunggah/).first().waitFor({ timeout: 30000 });
  await shot(brand, 'builder-1-basics');
  await next();
  // 2 Brief & aset
  await heading('Brief & aset');
  await brand.getByRole('textbox', { name: 'Brief' }).fill('**Brief QA** — potong momen terbaik trailer, durasi bebas.');
  const chip = async (label, value) => {
    const box = brand.getByRole('textbox', { name: label });
    await box.fill(value);
    await box.press('Enter');
  };
  await chip('Do (boleh/wajib)', 'Pakai subtitle');
  await chip("Don't (jangan)", 'Jangan pakai musik berhak cipta');
  await chip('Hashtag wajib', '#' + S.hashtag);
  await brand.locator('input[type=file]').first().setInputFiles(PDF);
  await brand.getByText(/brief\.pdf terunggah/).first().waitFor({ timeout: 30000 });
  await brand.getByRole('button', { name: 'Tambah pertanyaan' }).click();
  await brand.getByRole('textbox', { name: 'Pertanyaan', exact: true }).fill('Boleh pakai akun kedua?');
  await brand.getByRole('textbox', { name: 'Jawaban', exact: true }).fill('Boleh, asal terhubung.');
  await shot(brand, 'builder-2-brief');
  await next();
  // 3 Platform & rate: hanya TikTok, Rp10.000 / 1K
  await heading('Platform & rate');
  for (const p of ['Instagram', 'YouTube']) {
    const card = brand.locator('label', { hasText: p }).first();
    if ((await card.count()) && (await card.locator('input[type=checkbox]').isChecked())) await card.click();
  }
  await brand.getByLabel(/Rate semua platform/).fill('10000');
  await shot(brand, 'builder-3-platforms');
  await next();
  // 4 Reward & rule: tambah rule bonus milestone (10.000 views → Rp20.000)
  await heading('Reward & rule');
  await brand.getByRole('button', { name: 'Tambah rule' }).click();
  const kinds = brand.getByRole('combobox', { name: 'Jenis rule' });
  await kinds.last().click();
  await brand.getByRole('option', { name: /Bonus milestone/ }).click();
  await brand.getByRole('option').first().waitFor({ state: 'detached' });
  await brand.getByRole('textbox', { name: /Tembus di/ }).fill('10000');
  await brand.getByRole('textbox', { name: /^Bonus/ }).fill('20000');
  await shot(brand, 'builder-4-rewards');
  await next();
  // 5 Budget & batas
  await heading('Budget & batas');
  await brand.getByRole('textbox', { name: /^Budget/ }).first().fill('2000000');
  await brand.getByRole('textbox', { name: /Maks per klip/ }).fill('500000');
  await shot(brand, 'builder-5-budget');
  await next();
  // 6 Syarat clipper
  await heading('Syarat clipper');
  await brand.getByRole('textbox', { name: /Min follower/ }).fill('1000');
  await shot(brand, 'builder-6-eligibility');
  await next();
  // 7 Jadwal & review: mulai sekarang, deadline +14 hari, review oleh brand
  await heading('Jadwal & review');
  await brand.getByLabel(/^Mulai/).first().fill(wibInput(Date.now() - 60e3));
  await brand.getByLabel(/Batas submit/).fill(wibInput(Date.now() + 14 * 864e5));
  await brand.getByRole('radio', { name: /Direview brand/ }).check();
  await shot(brand, 'builder-7-schedule');
  await next();
  // Ringkasan
  await heading('Ringkasan & ajukan');
  await brand.getByText('Total dibayar').waitFor();
  await shot(brand, 'builder-8-summary');
  await brand.getByRole('button', { name: 'Ajukan', exact: true }).click();
  const dlg = brand.getByRole('alertdialog').or(brand.getByRole('dialog'));
  await dlg.getByRole('button', { name: 'Ajukan' }).click();
  await brand.getByText(/Campaign diajukan/).first().waitFor({ timeout: 30000 });
  await shot(brand, 'builder-9-submitted');
  const c = core(`select id || '|' || status || '|' || review_mode || '|' || array_to_string(platforms, ',') || '|' ||
                         array_to_string(required_hashtags, ',') || '|' || coalesce(slug, '') from market.campaigns
                  where org_id = '${S.orgId}' and title = ${lit(S.title)}`);
  const [cid, status, rm, plats, tags, slug] = c.split('|');
  check(status === 'in_review', 'campaign in_review: ' + c);
  check(rm === 'brand' && plats === 'tiktok' && tags === S.hashtag, 'kolom campaign: ' + c);
  S.campaignId = cid;
  S.slug = slug;
  // isi milik DB brand; admin mengajukan tepat versi isi yang tiba (gerbang content_version)
  const own = brandDb(`select title || '|' || content_version || '|' || (select count(*) from market.campaign_assets a where a.campaign_id = c.id)
                        from market.campaigns c where id = '${cid}'`);
  const rep = core(`select title || '|' || submitted_version || '|' || (select count(*) from market.campaign_assets a where a.campaign_id = c.id)
                    from market.campaigns c where id = '${cid}'`);
  check(own !== '' && own === rep, 'isi campaign di DB brand = replika yang diajukan di admin: ' + own + ' vs ' + rep);
  const rules = core(`select string_agg(kind || ':' || params::text, ' ; ' order by kind) from market.rate_rules where campaign_id = '${cid}'`);
  check(/milestone_bonus/.test(rules) && /per_1k_views/.test(rules) && /10000/.test(rules), 'rate rules: ' + rules);
  const pool = core(`select total || '|' || max_per_clip from finance.reward_pools where campaign_id = '${cid}'`);
  check(pool === '2000000|500000' || /^2000000(\.0+)?\|500000(\.0+)?$/.test(pool), 'pool: ' + pool);
  const assets = core(`select string_agg(kind || ':' || audience, ',' order by kind) from market.campaign_assets where campaign_id = '${cid}'`);
  check(/cover:clipper/.test(assets) && /document:clipper/.test(assets), 'aset cover + dokumen: ' + assets);
  const inv = core(`select id || '|' || status || '|' || kind || '|' || subtotal || '|' || mgmt_fee || '|' || admin_fee || '|' || tax || '|' || total || '|' || coalesce(number, '')
                    from finance.invoices where campaign_id = '${cid}'`);
  const [iid, ist, ikind, sub, mg, ad, tax, total, number] = inv.split('|');
  check(ist === 'issued' && ikind === 'campaign' && Number(sub) === 2000000, 'invoice issued: ' + inv);
  check(Number(mg) === 300000 && Number(ad) === 100000, 'fee 15% + 5%: ' + inv);
  check(Math.abs(Number(total) - (2000000 + 300000 + 100000 + Number(tax))) < 0.01, 'total = subtotal + fee + pajak: ' + inv);
  Object.assign(S, { invoiceId: iid, invoiceTotal: Number(total), invoiceNumber: number });
  log('brand: builder 7 langkah → in_review; rule', rules, '; invoice', number, total);
});

step('brand-billing', ['brand'], async ({ brand }) => {
  // B1.8
  await brand.goto(`${BRAND}/${S.orgSlug}/billing`);
  await brand.getByText(S.invoiceNumber).first().waitFor({ timeout: 30000 });
  await brand.getByText(/Belum dibayar/i).first().waitFor();
  await shot(brand, 'brand-billing-issued');
  log('brand: billing menampilkan invoice', S.invoiceNumber, 'Belum dibayar');
});

step('admin-confirm-payment', ['admin'], async ({ admin }) => {
  // A3.1: tidak ada payment gateway sandbox — admin finance mencocokkan mutasi lalu Konfirmasi (alur produk yang sebenarnya)
  await admin.goto(ADMIN + '/finance');
  if (core(`select status from finance.invoices where id = '${S.invoiceId}'`) === 'issued') {
  const row = admin.getByRole('row').filter({ hasText: S.invoiceNumber });
  await row.waitFor({ timeout: 30000 });
  await row.getByRole('button', { name: 'Konfirmasi' }).click();
  const dlg = admin.getByRole('dialog');
  await dlg.getByLabel(/Nomor referensi/).fill('QA-REF-' + S.stamp);
  await shot(admin, 'admin-confirm-dialog');
  await dlg.getByRole('button', { name: 'Konfirmasi' }).click();
  await dlg.waitFor({ state: 'detached', timeout: 20000 });
  } // (re-run ROLES_FROM: invoice sudah lunas dari percobaan sebelumnya)
  const st = core(`select status || '|' || payment_ref from finance.invoices where id = '${S.invoiceId}'`);
  check(st === `paid|QA-REF-${S.stamp}`, 'invoice paid: ' + st);
  const poolBal = core(`select coalesce(sum(e.amount), 0) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                        join finance.reward_pools p on p.id = a.owner_id where a.owner_type = 'campaign_pool' and p.campaign_id = '${S.campaignId}'`);
  check(Number(poolBal) === 2000000, 'saldo pool ledger = 2.000.000: ' + poolBal);
  await shot(admin, 'admin-confirmed');
  log('admin: pembayaran dikonfirmasi; pool ledger', poolBal);
});

step('admin-approve-campaign', ['admin', 'brand'], async ({ admin, brand }) => {
  // B1.9 / F-A02
  await admin.goto(`${ADMIN}/campaigns?id=${S.campaignId}`);
  await admin.getByText(S.title).first().waitFor({ timeout: 30000 });
  await shot(admin, 'admin-campaign-review');
  await admin.getByRole('button', { name: 'Setujui' }).first().click();
  const dlg = admin.getByRole('dialog');
  await dlg.getByRole('button', { name: 'Setujui' }).click();
  await dlg.waitFor({ state: 'detached', timeout: 20000 });
  let st = core(`select status from market.campaigns where id = '${S.campaignId}'`);
  check(st === 'scheduled' || st === 'live', 'campaign scheduled: ' + st);
  // job:lifecycle (pg_cron */5) membuat live pada start_at — dipanggil langsung supaya tidak menunggu 5 menit
  core('select market.run_lifecycle()');
  st = core(`select status from market.campaigns where id = '${S.campaignId}'`);
  check(st === 'live', 'campaign live setelah lifecycle: ' + st);
  await brand.goto(`${BRAND}/${S.orgSlug}/billing`);
  await brand.getByText(S.invoiceNumber).first().waitFor({ timeout: 30000 });
  await brand.getByText(/Lunas/).first().waitFor({ timeout: 15000 });
  await shot(brand, 'brand-billing-paid');
  log('admin: campaign disetujui → live; brand billing Lunas');
});

step('public-visible', ['anon'], async ({ anon }) => {
  // C1.1 / F-X02: campaign tayang di landing & /c/[slug]
  // Landing memakai unstable_cache revalidate 60 dtk (apps/web/src/features/landing/data.ts) → muat ulang sampai muncul
  await reloadUntil(anon, WEB + '/', anon.getByText(S.title).first(), 90000);
  await shot(anon, 'web-landing');
  await reloadUntil(anon, `${WEB}/c/${S.slug}`, anon.getByRole('heading', { name: S.title }), 90000);
  await anon.getByText(S.orgName).first().waitFor();
  await shot(anon, 'web-campaign-public');
  log('web: landing + /c/' + S.slug);
});

step('clipper-signup', ['clipper'], async ({ clipper }) => {
  // C1.2–C1.4 (akun baru tiap percobaan)
  const k = Date.now().toString(36);
  Object.assign(S, { clipperEmail: `roles-clip-${k}@clipper.localhost`, clipperUser: `rc_${k}` });
  await clipper.context().clearCookies();
  await clipper.goto(`${ACC}/login?next=${encodeURIComponent(APP + '/campaigns')}`);
  await signIn(clipper, S.clipperEmail);
  await clipper.waitForURL(/\/onboarding/, { timeout: 30000 });
  await clipper.getByLabel('Username').fill(S.clipperUser);
  await clipper.getByText('Username tersedia').waitFor({ timeout: 15000 });
  await clipper.getByLabel('Nama tampilan').fill('QA Clipper');
  for (const cb of await clipper.getByRole('checkbox').all()) await cb.check();
  await shot(clipper, 'clipper-onboarding');
  await clipper.getByRole('button', { name: 'Simpan & mulai' }).click();
  await clipper.waitForURL(APP + '/campaigns**', { timeout: 30000 });
  S.clipperId = core(`select id from market.profiles where username = ${lit(S.clipperUser)}`);
  check(S.clipperId, 'profil clipper');
  await clipper.getByText(S.title).first().waitFor({ timeout: 30000 });
  await shot(clipper, 'app-campaigns');
  // SIMULASI C1.5: OAuth TikTok tidak bisa offline → akun sosmed terverifikasi ditulis seperti worker_upsert_social_account
  S.accountId = core(`insert into tracking.social_accounts (user_id, platform, external_id, handle, followers, platform_created_at)
                      values ('${S.clipperId}', 'tiktok', 'tt-${S.clipperUser}', '${S.clipperUser}', 5000, now() - interval '400 days')
                      returning id`);
  log('clipper: onboarding → app/campaigns menampilkan campaign; akun TikTok (SQL)');
});

async function claimOnce(clipper, n) {
  await clipper.goto(`${APP}/campaigns/${S.campaignId}`);
  await clipper.getByText(S.orgName).first().waitFor({ timeout: 30000 });
  await clipper.getByRole('button', { name: 'Ambil Campaign' }).first().click();
  await clipper.getByRole('button', { name: 'Submit video' }).first().waitFor({ timeout: 20000 });
  const claim = core(`select id from market.claims where user_id = '${S.clipperId}' and campaign_id = '${S.campaignId}' and status = 'open'`);
  check(claim, 'claim open tercatat #' + n);
  return claim;
}

// SIMULASI C1.8: Edge Function core/social memvalidasi lewat API platform (offline tidak bisa) lalu memanggil
// api.worker_create_submission dengan service role — fungsi yang sama dipanggil di sini.
function createSubmission(claimId, n) {
  const post = `7392${Date.now()}${n}`;
  const url = `https://www.tiktok.com/@${S.clipperUser}/video/${post}`;
  const r = core(`select api.worker_create_submission('${S.clipperId}', '${claimId}', '${S.accountId}', '${post}', '${url}',
                   now(), 'klip QA #${S.hashtag}', 30, null)::text`);
  return { ...JSON.parse(r), url };
}

step('clipper-claim-submit', ['clipper'], async ({ clipper }) => {
  // C1.6 claim lewat UI
  const claim1 = await claimOnce(clipper, 1);
  await shot(clipper, 'app-claimed');
  // Aset brief (brief.pdf ~50 byte) tampil dengan ukuran yang masuk akal (bukan "0 MB")
  const assetLine = await clipper.getByText(/^Dokumen/).first().textContent();
  check(!/\b0 MB/.test(assetLine) && /\d B\b|KB|MB/.test(assetLine), 'ukuran aset: ' + assetLine);
  // C1.8 submit lewat UI: daftar video & tempel URL → API platform tidak terjangkau offline; catat pesan yang tampil
  await clipper.getByRole('button', { name: 'Submit video' }).first().click();
  const sheet = clipper.getByRole('dialog');
  await sheet.waitFor({ timeout: 15000 });
  await clipper.waitForTimeout(4000);
  await shot(clipper, 'app-submit-sheet');
  const paste = sheet.getByRole('button', { name: 'Tempel URL video' });
  if (await paste.count()) {
    await paste.click();
    await sheet.locator('input[type=url]').fill(`https://www.tiktok.com/@${S.clipperUser}/video/7392000000000000099`);
    await sheet.getByRole('button', { name: 'Submit', exact: true }).click();
    await clipper.waitForTimeout(6000);
    await shot(clipper, 'app-submit-offline-error');
    const alertText = (await sheet.getByRole('alert').allTextContents().catch(() => [])).join(' | ');
    const toastText = (await clipper.locator('[data-sonner-toast]').allTextContents().catch(() => [])).join(' | ');
    note('submit UI offline → alert:', alertText || '(none)', 'toast:', toastText || '(none)');
    S.submitUiError = alertText || toastText;
  } else note('sheet submit tanpa tombol Tempel URL video');
  await clipper.keyboard.press('Escape');
  const s1 = createSubmission(claim1, 1);
  check(s1.status === 'in_review', 'submisi #1 in_review (review brand): ' + JSON.stringify(s1));
  // claim kedua (submisi pertama menutup claim) → submisi #2
  const claim2 = await claimOnce(clipper, 2);
  const s2 = createSubmission(claim2, 2);
  check(s2.status === 'in_review', 'submisi #2 in_review');
  Object.assign(S, { sub1: s1.submission_id, sub2: s2.submission_id, url1: s1.url, url2: s2.url });
  await clipper.goto(APP + '/tasks');
  await clipper.getByText(S.title).first().waitFor({ timeout: 30000 });
  await clipper.getByText(/Review/).first().waitFor();
  await shot(clipper, 'app-tasks-review');
  const claims = core(`select string_agg(status::text, ',' order by created_at) from market.claims where user_id = '${S.clipperId}'`);
  check(claims === 'submitted,submitted', 'dua claim submitted: ' + claims);
  log('clipper: 2× claim UI + 2 submisi (SQL fungsi worker) → /tasks Review');
});

step('brand-review', ['brand'], async ({ brand }) => {
  // B3.2: approve #1, reject #2 dengan alasan
  await brand.goto(`${BRAND}/${S.orgSlug}/review`);
  if (core(`select status from tracking.submissions where id = '${S.sub2}'`) === 'in_review') {
  const card1 = brand.locator('li').filter({ hasText: S.url1 });
  const card2 = brand.locator('li').filter({ hasText: S.url2 });
  await card1.waitFor({ timeout: 30000 });
  await card2.waitFor();
  await shot(brand, 'brand-review-queue');
  await card1.getByRole('button', { name: 'Setujui', exact: true }).click();
  await brand.getByText(/1 klip disetujui/).first().waitFor({ timeout: 20000 });
  await card2.getByRole('button', { name: 'Tolak', exact: true }).click();
  const dlg = brand.getByRole('dialog');
  await dlg.waitFor();
  await dlg.getByRole('combobox').first().click();
  const opt = brand.getByRole('option').nth(1);
  S.rejectReasonLabel = (await opt.textContent()).trim();
  await opt.click();
  await dlg.getByRole('textbox').fill('Caption belum menyebut judul film.');
  await shot(brand, 'brand-reject-dialog');
  await dlg.getByRole('button', { name: 'Tolak klip' }).click();
  await brand.getByText(/1 klip ditolak/).first().waitFor({ timeout: 20000 });
  await shot(brand, 'brand-review-done');
  }
  const st = core(`select string_agg(status::text, ',' order by created_at) from tracking.submissions where user_id = '${S.clipperId}'`);
  check(st === 'tracking,rejected', 'status submisi tracking,rejected: ' + st);
  const dec = core(`select string_agg(decision || ':' || coalesce(reason_code, '') || ':' || coalesce(message, ''), ' ; ' order by id)
                    from trust.review_decisions where target_id in ('${S.sub1}', '${S.sub2}')`);
  check(/approve::/.test(dec) && /reject:[a-z_]+:Caption belum menyebut judul film\./.test(dec), 'keputusan + alasan + pesan: ' + dec);
  log('brand: approve + reject; keputusan', dec);
});

step('clipper-appeal', ['clipper'], async ({ clipper }) => {
  // C1.9: hasil review di /tasks + notifikasi; banding 1×
  await clipper.goto(APP + '/notifications');
  await clipper.waitForLoadState('networkidle');
  await shot(clipper, 'app-notifications');
  const notifs = core(`select string_agg(event, ',' order by id) from ops.notifications where user_id = '${S.clipperId}'`);
  check(/submission\.approved/.test(notifs) && /submission\.rejected/.test(notifs), 'notifikasi approved + rejected: ' + notifs);
  const body = await clipper.locator('main').innerText();
  check(/disetujui|lolos/i.test(body) && /ditolak/i.test(body), 'halaman notifikasi menampilkan hasil review');
  await clipper.goto(APP + '/tasks');
  await clipper.getByText(/Ditolak/).first().waitFor({ timeout: 30000 });
  await clipper.getByText('Caption belum menyebut judul film.').first().waitFor({ timeout: 10000 }).catch(() =>
    finding('pesan reject brand tidak tampil di /tasks'));
  await shot(clipper, 'app-tasks-rejected');
  await clipper.getByRole('button', { name: 'Banding' }).first().click();
  const dlg = clipper.getByRole('dialog');
  await dlg.getByRole('textbox').fill('Judul film ada di overlay teks video, mohon dicek ulang.');
  await dlg.getByRole('button', { name: 'Kirim banding' }).click();
  await clipper.getByText('Banding terkirim').first().waitFor({ timeout: 20000 });
  const st = core(`select status from tracking.submissions where id = '${S.sub2}'`);
  check(st === 'appealed', 'submisi #2 appealed: ' + st);
  await clipper.reload();
  await clipper.getByText(/Banding/).first().waitFor();
  await shot(clipper, 'app-tasks-appealed');
  log('clipper: notifikasi hasil review; banding terkirim');
});

step('admin-decide-appeal', ['admin'], async ({ admin }) => {
  // A4.1: banding (appealed) hanya diputus admin
  await admin.goto(ADMIN + '/review');
  const row = admin.locator('li, tr').filter({ hasText: S.clipperUser }).first();
  await row.waitFor({ timeout: 30000 });
  await shot(admin, 'admin-moderation-queue');
  await row.getByRole('checkbox').first().check();
  await admin.getByRole('button', { name: 'Setujui', exact: true }).first().click();
  await admin.getByText(/submisi diputus/).first().waitFor({ timeout: 20000 });
  const st = core(`select status from tracking.submissions where id = '${S.sub2}'`);
  check(st === 'tracking', 'banding diterima → tracking: ' + st);
  await shot(admin, 'admin-appeal-decided');
  log('admin: banding diterima → tracking');
});

step('tracking-earnings', ['clipper'], async ({ clipper }) => {
  // SIMULASI track-worker: API platform offline → api.worker_record_snapshot (RPC yang dipanggil track-worker) dengan views palsu
  const snap = (sid, views) =>
    JSON.parse(core(`select api.worker_record_snapshot('${sid}', ${views}, ${Math.round(views * 0.05)}, 10, 5, 'klip QA #${S.hashtag}', '{}'::jsonb)::text`));
  const r1 = snap(S.sub1, 15000);
  const r2 = snap(S.sub2, 3000);
  check(r1.snapshot_id && !r1.flagged && r2.snapshot_id && !r2.flagged, 'snapshot tercatat tanpa flag: ' + JSON.stringify([r1, r2]));
  // Harapan: #1 15.000 views × Rp10.000/1K = 150.000 + milestone 20.000 = 170.000 (cap 500.000 × 80% TikTok); #2 3.000 → 30.000
  const pend = core(`select coalesce(sum(e.amount), 0) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                     where a.owner_type = 'user_wallet' and a.owner_id = '${S.clipperId}' and e.state = 'pending'`);
  check(Number(pend) === 200000, 'pending wallet 200.000: ' + pend);
  await clipper.goto(APP + '/wallet');
  await clipper.getByText(/Pending/).first().waitFor({ timeout: 30000 });
  const w = await clipper.locator('main').innerText();
  check(/200\.000/.test(w), 'wallet UI menampilkan pending Rp200.000');
  await shot(clipper, 'app-wallet-pending');
  await clipper.goto(APP + '/tasks');
  await clipper.getByText(/15\.000/).first().waitFor({ timeout: 20000 });
  await shot(clipper, 'app-tasks-tracking');
  // SIMULASI waktu: view window (30 hari) lewat → snapshot final (lock) → hold 10 hari lewat → job earning-release
  core(`update tracking.submissions set posted_at = now() - interval '31 days' where id in ('${S.sub1}', '${S.sub2}')`);
  const f1 = snap(S.sub1, 15000);
  const f2 = snap(S.sub2, 3000);
  check(f1.locked && f2.locked, 'snapshot final → locked: ' + JSON.stringify([f1, f2]));
  core(`update tracking.submissions set locked_at = now() - interval '11 days' where id in ('${S.sub1}', '${S.sub2}')`);
  core('select finance.release_earnings()');
  const st = core(`select string_agg(status::text, ',') from tracking.submissions where id in ('${S.sub1}', '${S.sub2}')`);
  check(st === 'settled,settled', 'submisi settled: ' + st);
  const avail = core(`select coalesce(sum(e.amount), 0) from finance.ledger_entries e join finance.ledger_accounts a on a.id = e.account_id
                      where a.owner_type = 'user_wallet' and a.owner_id = '${S.clipperId}' and e.state = 'available'`);
  check(Number(avail) === 200000, 'available 200.000: ' + avail);
  await clipper.goto(APP + '/wallet');
  await clipper.getByText('Saldo tersedia').first().waitFor({ timeout: 30000 });
  check(/200\.000/.test(await clipper.locator('main').innerText()), 'wallet UI tersedia Rp200.000');
  await shot(clipper, 'app-wallet-available');
  log('tracking: pending 200.000 → release → tersedia 200.000');
});

step('clipper-kyc', ['clipper', 'admin'], async ({ clipper, admin }) => {
  // C1.12 KYC lewat accounts (Edge Function identity member-data) → A2.1 admin menyetujui
  await clipper.goto(`${ACC}/kyc?next=${encodeURIComponent(APP + '/wallet/withdraw')}`);
  await clipper.getByLabel(/Nama sesuai KTP/).fill('QA Clipper Satu');
  // NIK unik (FR-04: NIK sama di akun lain ditolak): wilayah 317101 + lahir 15-05-90 + 4 digit acak
  S.nik = '317101150590' + String(1000 + Math.floor(Math.random() * 9000));
  await clipper.getByLabel(/^NIK/).fill(S.nik);
  await clipper.locator('input[type=file]').first().setInputFiles(PNG);
  await clipper.getByRole('checkbox').first().check();
  await shot(clipper, 'accounts-kyc-form');
  await clipper.getByRole('button', { name: 'Kirim untuk verifikasi' }).click();
  await clipper.getByText(/Menunggu verifikasi/).first().waitFor({ timeout: 30000 });
  const k = ident(`select status from member.kyc_records where user_id = '${S.clipperId}'`);
  check(k === 'pending', 'kyc pending: ' + k);
  await shot(clipper, 'accounts-kyc-pending');
  await admin.goto(`${ADMIN}/users?tab=kyc&user=${S.clipperId}`);
  await admin.getByText('QA Clipper Satu').first().waitFor({ timeout: 30000 });
  await shot(admin, 'admin-kyc-detail');
  await admin.getByRole('button', { name: 'Setujui KYC' }).first().click();
  const dlg = admin.getByRole('dialog');
  await dlg.getByRole('button', { name: 'Setujui KYC' }).click();
  await dlg.waitFor({ state: 'detached', timeout: 20000 });
  const k2 = ident(`select status from member.kyc_records where user_id = '${S.clipperId}'`);
  check(k2 === 'approved', 'kyc approved: ' + k2);
  log('kyc: dikirim di accounts → disetujui admin');
});

step('clipper-payout-method', ['clipper'], async ({ clipper }) => {
  // C1.13
  await clipper.goto(`${ACC}/payout-methods?next=${encodeURIComponent(APP + '/wallet/withdraw')}`);
  await clipper.getByText('Tambah rekening').first().waitFor({ timeout: 30000 });
  const bank = clipper.getByRole('combobox', { name: /^Bank/ });
  await bank.click();
  await clipper.getByRole('option').first().click();
  S.accountNo = String(Date.now()).slice(-10); // unik (FR-04: bank + nomor sama di akun lain ditolak)
  await clipper.getByLabel(/Nomor rekening/).fill(S.accountNo);
  await clipper.getByLabel(/Nama pemilik/).fill('QA Clipper Satu');
  await shot(clipper, 'accounts-payout-form');
  await clipper.getByRole('button', { name: 'Simpan rekening' }).click();
  // C1.13 → next: kembali ke withdraw dengan rekening terpilih
  await clipper.waitForURL(new RegExp('^' + APP + '/wallet/withdraw\\?method_id='), { timeout: 30000 });
  await clipper.getByText(/\d rekening tersimpan/).first().waitFor({ timeout: 30000 });
  const pm = ident(`select count(*) || '|' || bool_and(account_no_enc is not null) || '|' || bool_and(account_name = 'QA Clipper Satu')
                    from member.payout_methods where user_id = '${S.clipperId}' and account_last4 = '${S.accountNo.slice(-4)}'`);
  check(pm === '1|true|true', 'payout method terenkripsi + last4 + nama: ' + pm);
  await clipper.goto(ACC + '/payout-methods');
  await clipper.getByText(new RegExp('•+ ?' + S.accountNo.slice(-4) + '|\\*+' + S.accountNo.slice(-4))).first().waitFor({ timeout: 30000 })
    .catch(() => finding('accounts/payout-methods: nomor tersamar ****' + S.accountNo.slice(-4) + ' tidak terlihat'));
  await shot(clipper, 'accounts-payout-saved');
  log('accounts: rekening tersimpan, tampil tersamar ****' + S.accountNo.slice(-4));
});

step('clipper-withdraw', ['clipper'], async ({ clipper }) => {
  // C1.11
  await clipper.goto(APP + '/wallet/withdraw');
  await clipper.getByText('Sebelum tarik').first().waitFor({ timeout: 30000 });
  await shot(clipper, 'app-withdraw-form');
  if (await clipper.getByText('Menunggu verifikasi').count()) {
    // Claim kyc di JWT ikut berubah baru saat token di-refresh (jwt_expiry 600 dtk, by design C1.12). Tanpa menunggu 10 menit:
    // keluar lalu masuk lagi di app (C2.2) → token baru membawa kyc=approved.
    finding('withdraw: KYC sudah approved tapi checklist masih "Menunggu verifikasi" sampai JWT di-refresh (≤10 menit, sesuai desain)');
    await clipper.context().clearCookies();
    await clipper.goto(`${APP}/login?next=${encodeURIComponent('/wallet/withdraw')}`);
    await signIn(clipper, S.clipperEmail);
    await clipper.waitForURL(APP + '/wallet/withdraw**', { timeout: 30000 });
    await clipper.getByText('Sebelum tarik').first().waitFor({ timeout: 30000 });
  }
  await clipper.getByText('Disetujui').first().waitFor({ timeout: 15000 });
  await clipper.getByRole('button', { name: 'Semua' }).click();
  const amt = clipper.getByRole('textbox', { name: /^Jumlah/ });
  check(digits(await amt.inputValue()) === 200000, 'tombol Semua mengisi 200.000: ' + (await amt.inputValue()));
  await shot(clipper, 'app-withdraw-filled');
  await clipper.getByRole('button', { name: 'Ajukan penarikan' }).click();
  await clipper.getByText(/Penarikan diajukan/).first().waitFor({ timeout: 30000 });
  await shot(clipper, 'app-withdraw-done');
  const p = core(`select status || '|' || amount || '|' || channel from finance.payouts where user_id = '${S.clipperId}'`);
  check(/^requested\|200000(\.0+)?\|batch$/.test(p), 'payout requested 200.000 batch: ' + p);
  await clipper.goto(APP + '/wallet');
  await clipper.getByText(/Menunggu batch/).first().waitFor({ timeout: 20000 });
  await shot(clipper, 'app-wallet-payout');
  log('clipper: payout batch diajukan', p);
});

step('brand-stats', ['brand'], async ({ brand }) => {
  // B3.1 / F-B08
  await brand.goto(`${BRAND}/${S.orgSlug}/campaigns/${S.campaignId}`);
  await brand.getByText(S.title).first().waitFor({ timeout: 30000 });
  await brand.waitForLoadState('networkidle');
  await shot(brand, 'brand-campaign-dashboard');
  const body = await brand.locator('main').innerText();
  check(/18\.000/.test(body), 'dashboard menampilkan 18.000 views valid');
  check(/200\.000/.test(body), 'dashboard menampilkan spend Rp200.000');
  check(/1\.800\.000/.test(body), 'dashboard menampilkan sisa pool Rp1.800.000');
  check(/\b1 clipper\b/.test(body), 'dashboard: 2 klip dari 1 clipper');
  check(/10%/.test(body), 'utilisasi budget 10%');
  log('brand: dashboard views 18.000, spend 200.000, sisa 1.800.000');
});

step('authz-negative', ['clipper', 'brand'], async ({ clipper, brand }) => {
  // Clipper bukan anggota org → tidak boleh melihat org brand; brand owner tidak boleh claim campaign org sendiri.
  await clipper.goto(`${BRAND}/${S.orgSlug}/campaigns`);
  await clipper.waitForLoadState('networkidle');
  const t = await clipper.locator('body').innerText();
  check(!t.includes(S.title), 'clipper (bukan anggota) tidak melihat campaign org di brand');
  await shot(clipper, 'authz-clipper-on-brand');
  log('authz: clipper tidak bisa membuka org brand');
});

async function reloadUntil(page, url, locator, ms) {
  const end = Date.now() + ms;
  for (;;) {
    await page.goto(url);
    if (await locator.waitFor({ timeout: 5000 }).then(() => true, () => false)) return;
    if (Date.now() > end) throw new Error('tidak muncul setelah ' + ms / 1000 + ' dtk di ' + url);
    await page.waitForTimeout(5000);
  }
}

// =============================== RUNNER ===============================

let pages = {};
const errors = [];
let stepNo = 0;
async function shot(page, name) {
  await page.screenshot({ path: `${OUT}/${String(stepNo).padStart(2, '0')}-${String(++shotN).padStart(2, '0')}-${name}.png`, fullPage: true, caret: 'initial' });
}

(async () => {
  const from = process.env.ROLES_FROM;
  const startIdx = from ? STEPS.findIndex((s) => s.name === from) : 0;
  if (startIdx < 0) throw new Error('langkah tidak dikenal: ' + from);
  if (startIdx === 0) for (const f of fs.readdirSync(OUT)) if (/\.png$|^session-/.test(f) && f !== 'cover.png') fs.rmSync(path.join(OUT, f));
  S = startIdx > 0 && fs.existsSync(STATE) ? JSON.parse(fs.readFileSync(STATE, 'utf8')) : freshState();
  const browser = await chromium.launch(process.env.E2E_HOST_RULES ? { args: [`--host-resolver-rules=${process.env.E2E_HOST_RULES}`] } : {});
  const ctxs = {};
  const role = async (r) => {
    if (pages[r]) return pages[r];
    const file = path.join(OUT, `session-${r}.json`);
    const opts = { viewport: r === 'brand' || r === 'admin' ? { width: 1280, height: 900 } : { width: 390, height: 844 }, locale: 'id-ID' };
    if (startIdx > 0 && fs.existsSync(file)) opts.storageState = file;
    ctxs[r] = await browser.newContext(opts);
    const p = await ctxs[r].newPage();
    p.on('pageerror', (e) => errors.push(`[${r}] pageerror ${p.url()}: ${e.message}`));
    p.on('console', (m) => m.type() === 'error' && errors.push(`[${r}] console ${p.url()}: ${m.text()}`));
    return (pages[r] = p);
  };
  let failed = null;
  const results = [];
  for (const s of STEPS.slice(startIdx)) {
    const arg = {};
    for (const r of s.roles) arg[r] = await role(r);
    stepNo = STEPS.indexOf(s) + 1;
    shotN = 0;
    const t0 = Date.now();
    try {
      await s.fn(arg);
      results.push(`PASS ${s.name} (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
    } catch (e) {
      failed = s.name;
      results.push(`FAIL ${s.name}: ${e.message.split('\n')[0]}`);
      for (const r of s.roles) await shot(pages[r], `FAIL-${s.name}-${r}`).catch(() => {});
      console.error('✗', s.name, e.message, '@', s.roles.map((r) => pages[r].url()).join(' '));
    }
    fs.writeFileSync(STATE, JSON.stringify(S, null, 2));
    for (const r of Object.keys(ctxs)) await ctxs[r].storageState({ path: path.join(OUT, `session-${r}.json`) });
    if (failed) break;
  }
  console.log('\n' + results.join('\n'));
  if (findings.length) console.log('\nTemuan:\n- ' + findings.join('\n- '));
  const relevant = errors.filter((e) => !/favicon|Download the React DevTools|\[Fast Refresh\]|HMR/.test(e));
  if (relevant.length) console.log('\nConsole/page errors:\n' + [...new Set(relevant)].join('\n'));
  await browser.close();
  if (failed) process.exitCode = 1;
})();
