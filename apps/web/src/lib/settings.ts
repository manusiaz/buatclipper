import type { Platform } from '@clipper/ui';
import { parseHomeBanners, type HomeBanner } from '@clipper/ui/banners';

export interface PublicSettings {
  minWithdrawIdr: number;
  managedServiceIdr: number | null;
  maxAccountsPerPlatform: number;
  claimHours: number;
  holdDays: number;
  platforms: Platform[];
  banners: HomeBanner[];
}

const ALL: Platform[] = ['tiktok', 'instagram', 'youtube', 'threads', 'facebook', 'x'];

/** Angka JSON atau string angka → number; selain itu null. */
export function num(v: unknown): number | null {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v.trim())) return Number(v);
  return null;
}

/** Baris ops.settings → nilai yang dipakai landing; kunci hilang/rusak → default PRD (§5, §7). appUrl: host path banner. */
export function publicSettings(rows: Array<{ key: string | null; value: unknown }>, appUrl = ''): PublicSettings {
  const get = (k: string) => rows.find((r) => r.key === `public.${k}`)?.value;
  const flags = get('flags.platforms');
  const enabled =
    flags && typeof flags === 'object' && !Array.isArray(flags)
      ? ALL.filter((p) => (flags as Record<string, unknown>)[p] === true)
      : [];
  const managed = num(get('billing.managed_service_idr'));
  return {
    minWithdrawIdr: num(get('finance.min_withdraw_idr')) ?? 100_000,
    managedServiceIdr: managed && managed > 0 ? managed : null,
    maxAccountsPerPlatform: num(get('market.max_accounts_per_platform')) ?? 3,
    claimHours: num(get('market.claim_hours')) ?? 48,
    holdDays: num(get('finance.hold_days')) ?? 7,
    platforms: enabled.length ? enabled : ['tiktok', 'instagram', 'youtube'],
    banners: parseHomeBanners(get('home.banners'), appUrl),
  };
}
