import { assert, assertEquals, assertStringIncludes, assertThrows } from "@std/assert";
import { escapeHtml, EVENTS, linksFromEnv, PROMO_EVENTS, render, safeHttpsUrl } from "./templates.ts";

const L = {
  app: "https://app.clipper.test",
  brand: "https://brand.clipper.test",
  accounts: "https://accounts.clipper.test",
  admin: "https://admin.clipper.test",
};
const ORG = "00000000-0000-0000-0000-0000000000aa";
const CAMP = "00000000-0000-0000-0000-0000000000cc";

Deno.test("templates: one template per F-X01 event (+ admin.alert), all render with an empty payload", () => {
  assertEquals(EVENTS.length, 41);
  assertEquals(new Set(EVENTS).size, 41);
  for (const e of EVENTS) {
    const r = render(e, {}, L, { unsubscribeUrl: PROMO_EVENTS.has(e) ? "https://app.clipper.test/u/1" : null });
    assert(r.subject.length > 0 && r.text.length > 0 && r.html.startsWith("<!doctype html>"), e);
    assert(/^https:\/\/(app|brand|accounts|admin)\.clipper\.test\//.test(r.push.url), `${e} → ${r.push.url}`);
    assert(r.push.title.length <= 80 && r.push.body.length <= 180, e);
  }
  assertThrows(() => render("payout.unknown", {}, L));
});

Deno.test("templates: deep links per event", () => {
  assertEquals(render("payout.paid", { amount: "150000.00" }, L).push.url, "https://app.clipper.test/wallet");
  assertEquals(
    render("claim.expiring", { campaign_id: CAMP }, L).push.url,
    `https://app.clipper.test/campaigns/${CAMP}`,
  );
  assertEquals(render("kyc.rejected", {}, L).push.url, "https://accounts.clipper.test/kyc");
  assertEquals(render("social.token_expired", {}, L).push.url, "https://app.clipper.test/social");
  assertEquals(
    render("budget.used", { org_id: ORG, campaign_id: CAMP, pct: 80 }, L).push.url,
    `https://brand.clipper.test/${ORG}/campaigns/${CAMP}`,
  );
  assertEquals(render("budget.used", { pct: 100, campaign_title: "MPL" }, L).subject, "Budget campaign MPL habis");
  assertEquals(
    render("budget.used", { pct: 80, campaign_title: "MPL" }, L).subject,
    "Budget campaign MPL terpakai 80%",
  );
  assertEquals(render("invoice.issued", { org_id: ORG }, L).push.url, `https://brand.clipper.test/${ORG}/billing`);
  assertEquals(
    render("submission.pending_review", { org_id: ORG }, L).push.url,
    `https://brand.clipper.test/${ORG}/review`,
  );
  assertEquals(
    render("managed.draft_ready", { org_id: ORG, campaign_id: CAMP }, L).push.url,
    `https://brand.clipper.test/${ORG}/campaigns/new?campaign=${CAMP}`,
  );
  assertEquals(render("campaign.live", {}, L).push.url, "https://brand.clipper.test/"); // no org → brand home
});

Deno.test("templates: amounts and dates in Indonesian format", () => {
  assertEquals(render("payout.paid", { amount: "150000.00" }, L).subject, "Payout Rp150.000 berhasil");
  assertEquals(render("payout.failed", { amount: 1250000.5 }, L).subject, "Payout Rp1.250.000,5 gagal");
  assertStringIncludes(
    render("claim.expiring", { expires_at: "2026-10-19T05:00:00Z", campaign_title: "MPL" }, L).text,
    "19 Oktober 2026",
  );
  assertStringIncludes(render("claim.expiring", { expires_at: "2026-10-19T05:00:00Z" }, L).text, "WIB");
});

Deno.test("templates: interpolated values are HTML-escaped; links cannot be redirected", () => {
  const evil = '<script>alert(1)</script>"><img src=x onerror=alert(2)>';
  const r = render("submission.rejected", { campaign_title: evil, reason: evil }, L);
  assert(!r.html.includes("<script>"));
  assert(!r.html.includes("<img"));
  assertStringIncludes(r.html, "&lt;script&gt;alert(1)&lt;/script&gt;&quot;&gt;&lt;img");
  for (const id of ["../../evil", "https://evil.test", "a/b", "%2e%2e", ""]) {
    assertEquals(
      render("campaign.new", { campaign_id: id }, L, { unsubscribeUrl: "https://app.clipper.test/u" }).push.url,
      "https://app.clipper.test/campaigns",
    );
    assertEquals(render("campaign.approved", { org_id: id }, L).push.url, "https://brand.clipper.test/");
  }
  const b = render("broadcast.sent", { title: "Info <b>baru</b>", body: "baris 1\nbaris <2>" }, L, {
    unsubscribeUrl: 'https://app.clipper.test/u?a=1&b="x"',
  });
  assertStringIncludes(b.html, "baris 1<br>baris &lt;2&gt;");
  assertStringIncludes(b.html, "<title>Info &lt;b&gt;baru&lt;/b&gt;</title>");
  assertStringIncludes(b.html, 'href="https://app.clipper.test/u?a=1&amp;b=%22x%22"');
  assertStringIncludes(b.text, "Berhenti menerima email promosi: https://app.clipper.test/u?a=1&b=%22x%22");
});

Deno.test("templates: unsubscribe URL and base URL validation", () => {
  assertEquals(safeHttpsUrl("javascript:alert(1)"), null);
  assertEquals(safeHttpsUrl("http://evil.test/u"), null);
  assertEquals(safeHttpsUrl("https://app.clipper.test/u/1"), "https://app.clipper.test/u/1");
  assertEquals(escapeHtml(`<&>"'`), "&lt;&amp;&gt;&quot;&#39;");
  const env: Record<string, string> = {
    APP_URL: "https://app.clipper.test/",
    BRAND_URL: "https://brand.clipper.test",
    ACCOUNTS_URL: "http://accounts.clipper.localhost:3000",
    ADMIN_URL: "https://admin.clipper.test",
  };
  assertEquals(linksFromEnv((n) => env[n]).app, "https://app.clipper.test");
  assertEquals(linksFromEnv((n) => env[n]).accounts, "http://accounts.clipper.localhost:3000");
  // ADMIN_URL baru: belum diisi tidak boleh mematikan email lain
  assertEquals(linksFromEnv((n) => ({ ...env, ADMIN_URL: undefined })[n]).admin, "");
  assertThrows(() => linksFromEnv((n) => ({ ...env, APP_URL: "http://app.clipper.test" })[n]));
});

// Regresi 2026-10-19: payload SQL asli (bukan bentuk yang diasumsikan template).
Deno.test("templates: payload SQL campaign.new (platforms[]) dan earning.available (amounts[])", () => {
  const unsub = { unsubscribeUrl: "https://app.clipper.test/u/1" };
  assertStringIncludes(
    render("campaign.new", { campaign_title: "MPL", platforms: ["tiktok", "youtube"] }, L, unsub).text,
    "untuk TikTok, YouTube",
  );
  const amounts = [{ amount: 15000.5, reward_type: "IDR", unit_label: "Rp" }, {
    amount: 120,
    reward_type: "DIAMOND",
    unit_label: "Diamonds",
  }];
  assertStringIncludes(render("earning.available", { amounts }, L).text, "Rp15.000,5 + 120 Diamonds sudah Tersedia");
});

Deno.test("templates: submission.approved push carries 2 actions (DS: Lihat saldo / Kirim clip lagi), others none", () => {
  const r = render("submission.approved", { campaign_id: CAMP, campaign_title: "Kuasa Gelap 2" }, L);
  assertEquals(r.push.actions, [
    { action: "wallet", title: "Lihat saldo", url: "https://app.clipper.test/wallet" },
    { action: "campaign", title: "Kirim clip lagi", url: `https://app.clipper.test/campaigns/${CAMP}` },
  ]);
  assertEquals(render("payout.paid", {}, L).push.actions, undefined);
});

// DS Android v2: "Notif selalu ada angka — views, rupiah, tanggal cair. Bukan cuma 'ada update'."
const NOW = Date.parse("2026-10-21T07:00:00Z");
const IDR = (amount: number | string) => ({ amount, reward_type: "IDR", unit_label: "Rp" });

Deno.test("templates angka: submission.approved = views · ±earning · tanggal cair (body push), rate di email", () => {
  const r = render("submission.approved", {
    campaign_id: CAMP,
    campaign_title: "Kuasa Gelap 2",
    platform: "tiktok",
    views: 48210,
    rate_per_1k: 2000,
    est_amounts: [IDR(96400)],
    release_at: "2026-10-27T03:00:00Z",
  }, L);
  assertEquals(r.push.body, "48.210 views dihitung · ±Rp96.400 sejauh ini · cair ±27 Okt");
  assertEquals(r.push.title, "Submisi kamu di Kuasa Gelap 2 disetujui");
  assertStringIncludes(r.text, "Video TikTok kamu di campaign Kuasa Gelap 2 disetujui");
  assertStringIncludes(r.text, "dengan rate Rp2.000/1K views");
  assertStringIncludes(r.text, "Angka ± adalah perkiraan");
  assertEquals(r.push.actions?.length, 2); // tombol DS tetap
  // multi-reward + belum ada views: rate tidak diulang kalau estimasi ada
  assertEquals(
    render("submission.approved", {
      views: 0,
      rate_per_1k: "1500.00",
      est_amounts: [IDR(50000), { amount: 3, reward_type: "DIAMOND", unit_label: "Diamonds" }],
      release_at: "2026-11-02T00:00:00Z",
    }, L).push.body,
    "±Rp50.000 + 3 Diamonds sejauh ini · cair ±2 Nov",
  );
  // tanpa estimasi (views di bawah min_views): rate jadi angkanya
  assertEquals(
    render("submission.approved", { rate_per_1k: 2000, est_amounts: [] }, L).push.body,
    "Rp2.000/1K views",
  );
});

Deno.test("templates angka: payout.processing (baru) — nominal, rekening tersamar opsional, ETA relatif saat render", () => {
  assert((EVENTS as readonly string[]).includes("payout.processing"));
  assert(!PROMO_EVENTS.has("payout.processing"), "transaksional: email + push, tanpa unsubscribe");
  const base = { payout_id: "p1", payout_method_id: "m1", ...IDR(482000), fee: 5000, channel: "instant" };
  const eta = new Date(NOW + 2 * 60_000).toISOString();
  const r = render("payout.processing", { ...base, eta_at: eta, bank_code: "BCA", account_last4: "4821" }, L, {
    now: NOW,
  });
  assertEquals(r.push.title, "Penarikan Rp482.000 sedang diproses");
  assertEquals(r.push.body, "Lagi ditransfer Rp482.000 ke BCA •• 4821 · ±2 menit.");
  assertEquals(r.push.url, "https://app.clipper.test/wallet");
  assertStringIncludes(r.text, "Perkiraan selesai 21 Oktober 2026 pukul 14.02 WIB.");
  assertStringIncludes(r.text, "Biaya tarik instan Rp5.000 sudah dipotong.");
  // batch: tanpa rekening dari bridge, tanpa biaya, 30 menit
  const b = render(
    "payout.processing",
    {
      ...base,
      fee: 0,
      channel: "batch",
      eta_at: new Date(NOW + 30 * 60_000).toISOString(),
    },
    L,
    { now: NOW },
  );
  assertEquals(b.push.body, "Lagi ditransfer Rp482.000 · ±30 menit.");
  assert(!b.text.includes("Biaya"));
  assertEquals(
    render("payout.processing", { ...base, eta_at: eta }, L, { now: NOW + 5 * 60_000 }).push.body,
    "Lagi ditransfer Rp482.000 · sebentar lagi.",
  );
  assertEquals(render("payout.processing", {}, L).push.body, "Lagi ditransfer dana kamu.");
});

Deno.test("templates angka: payout.paid / failed / cancelled membawa nominal, rekening & tanggal", () => {
  const paid = render("payout.paid", {
    ...IDR(150000),
    payout_id: "p1",
    fee: 0,
    paid_at: "2026-10-21T07:05:00Z",
    bank_code: "BANK_JAGO",
    account_last4: "0042",
  }, L);
  assertEquals(paid.subject, "Payout Rp150.000 berhasil");
  assertEquals(
    paid.push.body,
    "Rp150.000 sudah ditransfer ke BANK JAGO •• 0042 pada 21 Oktober 2026 pukul 14.05 WIB. Waktu masuk tergantung bank atau e-wallet tujuan.",
  );
  assertStringIncludes(render("payout.paid", IDR(95000), L).text, "Rp95.000 sudah ditransfer ke rekening kamu.");
  assertStringIncludes(render("payout.paid", { ...IDR(95000), fee: 5000 }, L).text, "Biaya tarik instan Rp5.000");
  assertStringIncludes(
    render("payout.failed", { ...IDR(150000), bank_code: "BCA", account_last4: "4821" }, L).text,
    "Saldo Rp150.000 sudah kembali ke wallet. Periksa rekening BCA •• 4821",
  );
  assertEquals(
    render("payout.cancelled", IDR(100000), L).push.body,
    "Saldo Rp100.000 sudah kembali ke Tersedia dan bisa kamu tarik lagi.",
  );
});

Deno.test("templates angka: claim, earning, submisi, campaign, sosmed, reward", () => {
  assertEquals(render("claim.expiring", { hours_left: 5 }, L).subject, "Claim kamu habis ±5 jam lagi");
  const av = render("earning.available", { campaign_title: "MPL", views: 48210, amounts: [IDR(96400)] }, L);
  assertEquals(av.subject, "Rp96.400 siap ditarik");
  assertEquals(av.push.body, "Rp96.400 dari 48.210 views di campaign MPL sudah Tersedia di wallet dan bisa ditarik.");
  const held = render("earning.held", { submission_id: "s1", campaign_title: "MPL", amounts: [IDR(12000)] }, L);
  assertEquals(held.subject, "Rp12.000 ditahan sementara");
  assertStringIncludes(held.text, "Earning Rp12.000 dari video kamu di campaign MPL ditahan");
  assertStringIncludes(
    render("earning.held", { amounts: [IDR(802502)] }, L).text,
    "Penarikan saldo Rp802.502 kamu ditahan",
  );
  assertEquals(
    render("submission.rejected", { campaign_title: "MPL", platform: "tiktok", views: 48210 }, L).push.body,
    "Video TikTok kamu di campaign MPL (48.210 views) ditolak.",
  );
  const gone = render("submission.forfeited", { campaign_title: "MPL", views: 1200, amounts: [IDR(2400)] }, L);
  assertEquals(gone.subject, "Earning Rp2.400 hangus");
  assertStringIncludes(gone.text, "Video kamu di campaign MPL (1.200 views) tidak bisa diakses lagi");
  assertStringIncludes(
    render("submission.forfeited", { reason: "fraud:FR-10", views: 5000 }, L).text,
    "Earning video kamu di campaign ini (5.000 views) dibatalkan",
  );
  assertStringIncludes(
    render("campaign.new", { campaign_title: "MPL", platforms: ["tiktok"], rate_per_1k: 2500 }, L, {
      unsubscribeUrl: "https://app.clipper.test/u/1",
    }).push.body,
    "untuk TikTok: MPL · rate sampai Rp2.500/1K views.",
  );
  assertStringIncludes(render("campaign.invited", { rate_per_1k: 3000 }, L).text, "rate sampai Rp3.000/1K views");
  assertStringIncludes(
    render("social.token_expired", { platform: "tiktok", handle: "andi", paused_count: 3 }, L).text,
    "tracking views 3 video berhenti sementara",
  );
  assertStringIncludes(
    render("fulfillment.delivered", {
      amount: 120,
      reward_type: "DIAMOND",
      unit_label: "Diamonds",
      reward_name: "Diamonds",
    }, L)
      .text,
    "120 Diamonds sudah dikirim",
  );
});

Deno.test("templates angka: field hilang/rusak (baris antrean lama) tetap render tanpa angka palsu", () => {
  const junk = {
    views: "-5",
    hours_left: "1e9",
    rate_per_1k: "abc",
    est_amounts: [null, "x", { amount: "abc", reward_type: "IDR" }],
    amounts: [null, 7],
    release_at: "bukan tanggal",
    eta_at: 42,
    paid_at: "x",
    fee: "gratis",
    paused_count: -1,
    bank_code: "<b>BCA</b>",
    account_last4: "12345",
  };
  for (const e of EVENTS) {
    const r = render(e, junk, L, {
      unsubscribeUrl: PROMO_EVENTS.has(e) ? "https://app.clipper.test/u/1" : null,
      now: NOW,
    });
    assert(!/NaN|undefined|null|Invalid|<b>|±\s|Rp0\b/.test(r.text), `${e}: ${r.text}`);
  }
  assertEquals(
    render("submission.approved", { campaign_title: "MPL" }, L).push.body,
    "Video kamu di campaign MPL disetujui. Views-nya sekarang dihitung untuk earning.",
  );
  assertEquals(render("claim.expiring", {}, L).subject, "Claim kamu hampir kedaluwarsa");
  assertEquals(render("earning.available", {}, L).subject, "Earning siap ditarik");
  assertEquals(render("payout.paid", {}, L).push.body.startsWith("Dana sudah ditransfer ke rekening kamu."), true);
});

Deno.test("templates angka: nilai payload baru tetap di-escape", () => {
  const evil = "<img src=x onerror=alert(1)>";
  const r = render("submission.approved", {
    campaign_title: evil,
    platform: evil,
    est_amounts: [{ amount: 5, reward_type: evil, unit_label: evil }],
    release_at: "2026-10-27T03:00:00Z",
  }, L);
  assert(!r.html.includes("<img"));
  assertStringIncludes(r.html, "&lt;img src=x onerror=alert(1)&gt;");
  const p = render("payout.processing", { ...IDR(1000), bank_code: '"><script>', account_last4: "<b>1</b>" }, L);
  assert(!p.html.includes("<script>") && !p.text.includes("script"));
  const f = render("fulfillment.delivered", { amount: 1, reward_type: "V", unit_label: evil, reward_name: evil }, L);
  assert(!f.html.includes("<img"));
});

Deno.test("templates: submission.rejected final (banding ditolak / campaign tutup) tidak menawarkan banding", () => {
  assertStringIncludes(render("submission.rejected", { reason: "x" }, L).text, "banding");
  assert(!render("submission.rejected", { reason: "x", final: true }, L).text.includes("banding"));
});
