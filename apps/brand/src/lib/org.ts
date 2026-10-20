import { cache } from 'react';
import { notFound } from 'next/navigation';
import { coreServer, requireBrand } from '@clipper/auth/server';
import type { CoreClient, CoreView } from '@clipper/db-core';

export type OrgRole = 'brand_owner' | 'brand_manager' | 'brand_finance' | 'brand_viewer';
export type Org = CoreView<'organizations'> & { id: string; name: string };

const ROLE_ORDER: OrgRole[] = ['brand_owner', 'brand_manager', 'brand_finance', 'brand_viewer'];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const isUuid = (v: unknown): v is string => typeof v === 'string' && UUID_RE.test(v);

/** Hak UI per role (§4); database tetap mengecek lagi. */
const PERMS = {
  edit: ['brand_owner', 'brand_manager'],
  review: ['brand_owner', 'brand_manager'],
  billing: ['brand_owner', 'brand_finance'],
  fund: ['brand_owner', 'brand_manager', 'brand_finance'],
} as const satisfies Record<string, readonly OrgRole[]>;

export type Perm = keyof typeof PERMS;
export const can = (role: OrgRole, perm: Perm) => (PERMS[perm] as readonly OrgRole[]).includes(role);

/** Semantik ops.org_role: role langsung, kalau tidak ada role terbaik lewat agency yang tertaut & disetujui. */
async function roleIn(core: CoreClient, orgId: string, userId: string): Promise<{ role: OrgRole; direct: boolean } | null> {
  const { data: own } = await core.from('org_members').select('role').eq('org_id', orgId).eq('user_id', userId).maybeSingle();
  if (own?.role) return { role: own.role, direct: true };
  const { data: links } = await core
    .from('org_links')
    .select('agency_org_id')
    .eq('client_org_id', orgId)
    .not('approved_at', 'is', null)
    .is('revoked_at', null);
  const agencies = (links ?? []).map((l) => l.agency_org_id).filter(isUuid);
  if (!agencies.length) return null;
  const { data: via } = await core.from('org_members').select('role').in('org_id', agencies).eq('user_id', userId);
  const best = ROLE_ORDER.find((r) => via?.some((m) => m.role === r));
  return best ? { role: best, direct: false } : null;
}

/** Org dari URL + role pemanggil; dibagi layout & page dalam satu request. Bukan anggota → 404. */
export const getOrgContext = cache(async (orgId: string) => {
  const { claims } = await requireBrand();
  if (!isUuid(orgId)) notFound();
  const core = await coreServer();
  const { data: org } = await core
    .from('organizations')
    .select('id, name, org_type, legal_name, npwp, address, is_agency, status, verified_at, created_at, updated_at, fee_rule_id')
    .eq('id', orgId)
    .maybeSingle();
  if (!org?.id || !org.name) notFound();
  const member = await roleIn(core, orgId, claims.sub);
  if (!member) notFound();
  return { claims, core, org: org as Org, role: member.role, direct: member.direct };
});

export type OrgContext = Awaited<ReturnType<typeof getOrgContext>>;

/** Nilai config publik (public.billing.*, public.flags.*). */
export async function publicSettings(core: CoreClient, keys: string[]): Promise<Record<string, unknown>> {
  const { data } = await core.from('settings').select('key, value').in('key', keys);
  return Object.fromEntries((data ?? []).map((s) => [s.key, s.value]));
}

export const num = (v: unknown, fallback = 0): number => {
  const n = typeof v === 'number' ? v : typeof v === 'string' ? Number(v) : NaN;
  return Number.isFinite(n) ? n : fallback;
};
