import type { IconName } from '@clipper/ui';
import type { PlatformRole } from '@clipper/auth';

export type NavKey =
  | 'overview' | 'campaigns' | 'builder' | 'pinned' | 'review' | 'fraud' | 'users' | 'finance' | 'fulfillment' | 'config'
  | 'audit' | 'broadcast';

/** Menu admin (§6.8) + role yang melihatnya (§4). Kosong = semua admin; admin_super selalu lolos. */
export const NAV: { section: 'main' | 'campaign' | 'trust' | 'money' | 'platform'; key: NavKey; href: string; icon: IconName; roles: PlatformRole[] }[] = [
  { section: 'main', key: 'overview', href: '/', icon: 'space_dashboard', roles: [] },
  { section: 'campaign', key: 'campaigns', href: '/campaigns', icon: 'campaign', roles: ['admin_ops'] },
  { section: 'campaign', key: 'builder', href: '/campaigns/new', icon: 'movie_edit', roles: ['admin_ops'] },
  { section: 'campaign', key: 'pinned', href: '/pinned', icon: 'keep', roles: ['admin_ops'] },
  { section: 'trust', key: 'review', href: '/review', icon: 'checklist', roles: ['admin_moderator'] },
  { section: 'trust', key: 'fraud', href: '/fraud', icon: 'gavel', roles: ['admin_moderator'] },
  { section: 'trust', key: 'users', href: '/users', icon: 'manage_accounts', roles: ['admin_ops', 'admin_moderator', 'admin_support'] },
  { section: 'money', key: 'finance', href: '/finance', icon: 'payments', roles: ['admin_finance'] },
  { section: 'money', key: 'fulfillment', href: '/fulfillment', icon: 'redeem', roles: ['admin_ops', 'admin_finance'] },
  { section: 'platform', key: 'config', href: '/config', icon: 'tune', roles: ['admin_super'] },
  { section: 'platform', key: 'audit', href: '/audit', icon: 'history', roles: ['admin_super'] },
  { section: 'platform', key: 'broadcast', href: '/broadcast', icon: 'send', roles: ['admin_ops'] },
];

export const rolesFor = (key: NavKey): PlatformRole[] => NAV.find((n) => n.key === key)!.roles;

export function allowed(userRoles: readonly string[], roles: readonly PlatformRole[]): boolean {
  if (!userRoles.some((r) => r.startsWith('admin_'))) return false;
  return roles.length === 0 || userRoles.includes('admin_super') || roles.some((r) => userRoles.includes(r));
}

export const navFor = (userRoles: readonly string[]) => NAV.filter((n) => allowed(userRoles, n.roles));

/** Item aktif = href terpanjang yang menjadi prefix path ('/' hanya cocok persis). */
export function activeHref(pathname: string, hrefs: readonly string[]): string | null {
  let best: string | null = null;
  for (const h of hrefs) {
    const hit = h === '/' ? pathname === '/' : pathname === h || pathname.startsWith(`${h}/`);
    if (hit && (!best || h.length > best.length)) best = h;
  }
  return best;
}
