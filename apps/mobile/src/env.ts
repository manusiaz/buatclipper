// Nilai publik (EXPO_PUBLIC_*, di-inline Metro saat build): project identity & core + host web untuk langkah di browser.
const need = (v: string | undefined, name: string): string => {
  if (!v) throw new Error(`${name} belum diisi (apps/mobile/.env, lihat .env.example)`);
  return v.replace(/\/+$/, '');
};

export const env = {
  identityUrl: need(process.env.EXPO_PUBLIC_IDENTITY_URL, 'EXPO_PUBLIC_IDENTITY_URL'),
  identityKey: need(process.env.EXPO_PUBLIC_IDENTITY_PUBLISHABLE_KEY, 'EXPO_PUBLIC_IDENTITY_PUBLISHABLE_KEY'),
  coreUrl: need(process.env.EXPO_PUBLIC_CORE_URL, 'EXPO_PUBLIC_CORE_URL'),
  coreKey: need(process.env.EXPO_PUBLIC_CORE_PUBLISHABLE_KEY, 'EXPO_PUBLIC_CORE_PUBLISHABLE_KEY'),
  brandDbUrl: need(process.env.EXPO_PUBLIC_BRAND_DB_URL, 'EXPO_PUBLIC_BRAND_DB_URL'),
  brandDbKey: need(process.env.EXPO_PUBLIC_BRAND_DB_PUBLISHABLE_KEY, 'EXPO_PUBLIC_BRAND_DB_PUBLISHABLE_KEY'),
  appUrl: need(process.env.EXPO_PUBLIC_APP_URL, 'EXPO_PUBLIC_APP_URL'),
  accountsUrl: need(process.env.EXPO_PUBLIC_ACCOUNTS_URL, 'EXPO_PUBLIC_ACCOUNTS_URL'),
  brandUrl: need(process.env.EXPO_PUBLIC_BRAND_URL, 'EXPO_PUBLIC_BRAND_URL'),
  /** Landing {domain}: link referral /?ref=… (sama dengan hosts.web app). */
  webUrl: need(process.env.EXPO_PUBLIC_WEB_URL, 'EXPO_PUBLIC_WEB_URL'),
};
