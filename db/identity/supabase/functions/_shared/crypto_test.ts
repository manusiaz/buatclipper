import { assertEquals, assertNotEquals, assertRejects, assertThrows } from "@std/assert";
import { b64encode, fromPgBytea, loadPiiKeys, PiiCrypto, timingSafeEqual, toHex, toPgBytea } from "./crypto.ts";
import { ConfigError, HttpError } from "./http.ts";
import { testKeys } from "./testing.ts";

Deno.test("HMAC: digits-only normalization gives one hash per NIK/account", async () => {
  const c = new PiiCrypto(testKeys());
  const a = toHex(await c.hmac("3171011205900001"));
  assertEquals(toHex(await c.hmac("3171 0112 0590 0001")), a);
  assertEquals(toHex(await c.hmac("3171-0112.0590-0001")), a);
  assertNotEquals(toHex(await c.hmac("3171011205900002")), a);
  assertEquals((await c.hmac("123")).length, 32); // E-05/E-16 CHECK octet_length = 32
  await assertRejects(() => c.hmac(" - . "), HttpError);
});

Deno.test("HMAC: keyed — a different key gives a different hash (not a plain SHA-256)", async () => {
  const env1 = {
    PII_HMAC_KEY: b64encode(new Uint8Array(32).fill(1)),
    PII_ENC_KEYS: JSON.stringify({ 1: b64encode(new Uint8Array(32)) }),
    PII_ENC_KEY_VERSION: "1",
  } as Record<string, string>;
  const env2: Record<string, string> = { ...env1, PII_HMAC_KEY: b64encode(new Uint8Array(32).fill(2)) };
  const h1 = toHex(await new PiiCrypto(loadPiiKeys((n) => env1[n])).hmac("3171011205900001"));
  const h2 = toHex(await new PiiCrypto(loadPiiKeys((n) => env2[n])).hmac("3171011205900001"));
  assertNotEquals(h1, h2);
});

Deno.test("AES-GCM: round trip, random IV, IV||ct+tag layout", async () => {
  const c = new PiiCrypto(testKeys());
  const a = await c.encrypt("kyc.nik", "3171011205900001");
  const b = await c.encrypt("kyc.nik", "3171011205900001");
  assertEquals(a.version, 1);
  assertEquals(a.ciphertext.length, 12 + 16 + 16); // iv + 16-byte plaintext + tag
  assertNotEquals(toHex(a.ciphertext), toHex(b.ciphertext));
  assertEquals(await c.decrypt("kyc.nik", a.ciphertext, a.version), "3171011205900001");
});

Deno.test("AES-GCM: tampering, wrong purpose (AAD) and unknown version fail", async () => {
  const c = new PiiCrypto(testKeys());
  const a = await c.encrypt("payout.account_no", "8881234567");
  const t = a.ciphertext.slice();
  t[t.length - 1] ^= 1;
  await assertRejects(() => c.decrypt("payout.account_no", t, 1), HttpError, "rusak");
  await assertRejects(() => c.decrypt("kyc.nik", a.ciphertext, 1), HttpError, "rusak");
  await assertRejects(() => c.decrypt("payout.account_no", a.ciphertext, 9), HttpError);
});

Deno.test("key rotation: new data uses the current version, old ciphertext still decrypts", async () => {
  const v1 = new PiiCrypto(testKeys({ 1: 1 }, 1));
  const old = await v1.encrypt("recipient.data", '{"phone":"0812"}');
  const v2 = new PiiCrypto(testKeys({ 1: 1, 2: 2 }, 2));
  const fresh = await v2.encrypt("recipient.data", "x");
  assertEquals(fresh.version, 2);
  assertEquals(await v2.decrypt("recipient.data", old.ciphertext, old.version), '{"phone":"0812"}');
  // decrypting the v1 ciphertext with the v2 key fails (version is load-bearing)
  await assertRejects(() => v2.decrypt("recipient.data", old.ciphertext, 2), HttpError);
});

Deno.test("PostgREST bytea round trip", () => {
  const u = new Uint8Array([0, 1, 254, 255]);
  assertEquals(toPgBytea(u), "\\x0001feff");
  assertEquals(fromPgBytea("\\x0001feff"), u);
  assertThrows(() => fromPgBytea("0001"));
});

Deno.test("config: missing/short/bad keys are config errors", () => {
  const base = {
    PII_HMAC_KEY: b64encode(new Uint8Array(32)),
    PII_ENC_KEYS: JSON.stringify({ 1: b64encode(new Uint8Array(32)) }),
    PII_ENC_KEY_VERSION: "1",
  } as Record<string, string>;
  assertThrows(() => loadPiiKeys((n) => ({ ...base, PII_HMAC_KEY: b64encode(new Uint8Array(16)) })[n]), ConfigError);
  assertThrows(
    () => loadPiiKeys((n) => ({ ...base, PII_ENC_KEYS: JSON.stringify({ 1: b64encode(new Uint8Array(16)) }) })[n]),
    ConfigError,
  );
  assertThrows(() => loadPiiKeys((n) => ({ ...base, PII_ENC_KEY_VERSION: "2" })[n]), ConfigError);
  assertThrows(() => loadPiiKeys((n) => ({ ...base, PII_ENC_KEYS: "nope" })[n]), ConfigError);
});

Deno.test("timingSafeEqual", () => {
  assertEquals(timingSafeEqual("abc", "abc"), true);
  assertEquals(timingSafeEqual("abc", "abd"), false);
  assertEquals(timingSafeEqual("abc", "abcd"), false);
  assertEquals(timingSafeEqual("", ""), true);
});
