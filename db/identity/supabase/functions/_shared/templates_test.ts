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
  assertEquals(EVENTS.length, 40);
  assertEquals(new Set(EVENTS).size, 40);
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
