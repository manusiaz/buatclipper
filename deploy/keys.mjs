// Secret produksi deploy self-hosted, dibuat sekali ke deploy/secrets.env (sudah ada → tidak disentuh, supaya kunci tidak
// berubah diam-diam). Dijalankan deploy.sh lewat container node:22-alpine, jadi server cukup punya Docker.
//
// Pemisahan kunci (Invarian identity ↔ core):
// - Satu pasangan EC P-256: private key HANYA di GoTrue identity (menandatangani token user, kid sama di JWKS kedua stack),
//   public key di JWKS identity & core → core memverifikasi token user terbitan identity tanpa bisa menerbitkannya.
// - anon/service_role tiap stack = HS256 dengan JWT_SECRET masing-masing → service key core tidak berlaku di identity
//   dan sebaliknya (oct key hanya ada di JWKS stack-nya sendiri).
import crypto from 'node:crypto';
import fs from 'node:fs';

const out = process.argv[2] ?? 'secrets.env';
if (fs.existsSync(out)) {
  console.log(`${out} sudah ada, tidak diubah`);
  process.exit(0);
}

const b64u = (buf) => Buffer.from(buf).toString('base64url');
const rand = (n = 32) => crypto.randomBytes(n).toString('base64url');
const hex = (n = 32) => crypto.randomBytes(n).toString('hex');

function hs256(secret, payload) {
  const data = `${b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))}.${b64u(JSON.stringify(payload))}`;
  return `${data}.${crypto.createHmac('sha256', secret).update(data).digest('base64url')}`;
}

const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
const jwk = privateKey.export({ format: 'jwk' });
const kid = crypto.randomUUID();
const ecPublic = { kty: 'EC', kid, use: 'sig', key_ops: ['verify'], alg: 'ES256', ext: true, crv: jwk.crv, x: jwk.x, y: jwk.y };
const ecPrivate = { ...ecPublic, key_ops: ['sign', 'verify'], d: jwk.d };

const iat = Math.floor(Date.now() / 1000);
const exp = iat + 10 * 365 * 24 * 3600;
const lines = [];
for (const p of ['IDENTITY', 'CORE']) {
  const jwtSecret = rand(48);
  const oct = { kty: 'oct', k: b64u(jwtSecret), alg: 'HS256' };
  lines.push(
    `${p}_POSTGRES_PASSWORD=${hex(24)}`,
    `${p}_JWT_SECRET=${jwtSecret}`,
    `${p}_ANON_KEY=${hs256(jwtSecret, { role: 'anon', iss: 'supabase', iat, exp })}`,
    `${p}_SERVICE_ROLE_KEY=${hs256(jwtSecret, { role: 'service_role', iss: 'supabase', iat, exp })}`,
    `${p}_JWT_JWKS=${JSON.stringify({ keys: [ecPublic, oct] })}`,
    `${p}_SECRET_KEY_BASE=${rand(48)}`,
    `${p}_VAULT_ENC_KEY=${hex(16)}`,
    `${p}_PG_META_CRYPTO_KEY=${hex(16)}`,
    `${p}_DASHBOARD_PASSWORD=${hex(16)}`,
    `${p}_S3_PROTOCOL_ACCESS_KEY_ID=${hex(16)}`,
    `${p}_S3_PROTOCOL_ACCESS_KEY_SECRET=${hex(32)}`,
  );
  if (p === 'IDENTITY') lines.push(`IDENTITY_JWT_KEYS=${JSON.stringify([ecPrivate, oct])}`);
}

const ecdh = crypto.createECDH('prime256v1');
ecdh.generateKeys();
lines.push(
  `BRIDGE_SECRET_CORE_TO_IDENTITY=${rand()}`,
  `BRIDGE_SECRET_IDENTITY_TO_CORE=${rand()}`,
  `PII_HMAC_KEY=${crypto.randomBytes(32).toString('base64')}`, // base64 standar (crypto.ts b64decode)
  `PII_ENC_KEYS={"1":"${crypto.randomBytes(32).toString('base64')}"}`,
  'PII_ENC_KEY_VERSION=1',
  `UNSUBSCRIBE_SECRET=${rand()}`,
  `DISBURSE_CALLBACK_TOKEN=${rand()}`,
  `VAPID_PUBLIC_KEY=${b64u(ecdh.getPublicKey())}`,
  `VAPID_PRIVATE_KEY=${b64u(ecdh.getPrivateKey())}`,
);
fs.writeFileSync(out, `${lines.join('\n')}\n`, { mode: 0o600 });
console.log(`${out} dibuat`);
