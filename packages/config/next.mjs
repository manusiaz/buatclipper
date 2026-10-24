// Konfigurasi Next bersama 5 app. CSP ber-nonce dipasang proxy.ts (@clipper/auth/proxy), bukan di sini.
const SHARED = ['@clipper/ui', '@clipper/auth', '@clipper/db-core', '@clipper/db-identity', '@clipper/i18n', '@clipper/campaign-builder'];

/** @param {{ app: 'web'|'accounts'|'clipper'|'brand'|'admin', extra?: import('next').NextConfig }} opts */
export function clipperNextConfig({ app, extra = {} }) {
  const headers = [
    { key: 'X-Content-Type-Options', value: 'nosniff' },
    { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
    { key: 'X-Frame-Options', value: 'DENY' },
    { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=(), payment=()' },
    { key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains; preload' },
  ];
  if (app !== 'web') headers.push({ key: 'X-Robots-Tag', value: 'noindex, nofollow' });
  return {
    reactStrictMode: true,
    poweredByHeader: false,
    transpilePackages: SHARED,
    async headers() {
      return [{ source: '/(.*)', headers }];
    },
    ...extra,
  };
}
