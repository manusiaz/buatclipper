// Bagian @clipper/auth yang aman untuk client & server: host, claim, dan validasi parameter next (§6.7).
export type AppHost = 'web' | 'accounts' | 'app' | 'brand' | 'admin';
export type SessionKind = 'sso' | 'admin';

export const hosts: Record<AppHost, string> = {
  web: process.env.NEXT_PUBLIC_WEB_URL!,
  accounts: process.env.NEXT_PUBLIC_ACCOUNTS_URL!,
  app: process.env.NEXT_PUBLIC_APP_URL!,
  brand: process.env.NEXT_PUBLIC_BRAND_URL!,
  admin: process.env.NEXT_PUBLIC_ADMIN_URL!,
};

export type PlatformRole = 'admin_super' | 'admin_ops' | 'admin_moderator' | 'admin_finance' | 'admin_support';

/** Claim JWT identity (diisi member.custom_access_token_hook). */
export interface Claims {
  sub: string;
  email?: string;
  aal: 'aal1' | 'aal2';
  app_roles: PlatformRole[];
  kyc: 'none' | 'pending' | 'approved' | 'rejected';
  consent_ok: { clipper: boolean; brand: boolean };
  exp: number;
}

export const isAdmin = (c: Pick<Claims, 'app_roles'> | null | undefined): boolean =>
  !!c?.app_roles?.some((r) => r.startsWith('admin_'));

export const hasRole = (c: Pick<Claims, 'app_roles'> | null | undefined, ...roles: PlatformRole[]): boolean =>
  !!c?.app_roles?.some((r) => r === 'admin_super' || roles.includes(r));

/** next hanya boleh ke {domain}, app, brand, accounts — bukan admin, bukan domain luar (anti open redirect). */
export function safeNext(next: string | null | undefined, fallback = `${hosts.app}/campaigns`): string {
  if (!next) return fallback;
  if (next.startsWith('/') && !next.startsWith('//') && !next.startsWith('/\\')) return next;
  try {
    const url = new URL(next);
    const allowed = [hosts.web, hosts.app, hosts.brand, hosts.accounts].map((h) => new URL(h).origin);
    return allowed.includes(url.origin) ? url.toString() : fallback;
  } catch {
    return fallback;
  }
}

export const loginUrl = (next: string) => `${hosts.accounts}/login?next=${encodeURIComponent(next)}`;
export const onboardingUrl = (role: 'clipper' | 'brand', next: string) =>
  `${hosts.accounts}/onboarding?role=${role}&next=${encodeURIComponent(next)}`;
export const securityUrl = (next: string) => `${hosts.accounts}/security?next=${encodeURIComponent(next)}`;
export const kycUrl = (next: string) => `${hosts.accounts}/kyc?next=${encodeURIComponent(next)}`;
