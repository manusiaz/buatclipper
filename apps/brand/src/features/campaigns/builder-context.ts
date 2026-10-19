import { PLATFORMS, type BuilderContext, type Platform } from '@clipper/campaign-builder';
import { num, publicSettings, type OrgContext } from '@/lib/org';

/** Konteks builder (F-B02) dari api: kategori, reward type global + org, flag platform, fee efektif, pajak, paket managed. */
export async function builderContext({ core, org }: Pick<OrgContext, 'core' | 'org'>): Promise<BuilderContext> {
  const [{ data: categories }, { data: rewardTypes }, { data: rules }, { count: orgCount }, settings] = await Promise.all([
    core.from('categories').select('id, name_id, name_en, sort').eq('active', true).order('sort'),
    core
      .from('reward_types')
      .select('id, code, name, unit_label, kind, idr_value_per_unit, decimals, owner_org_id')
      .or(`owner_org_id.is.null,owner_org_id.eq.${org.id}`)
      .order('code'),
    core.from('fee_rules').select('scope, mgmt_fee_pct, admin_fee_pct'),
    core.from('organizations').select('id', { count: 'exact', head: true }),
    publicSettings(core, ['public.flags.platforms', 'public.billing.tax_pct', 'public.billing.managed_service_idr']),
  ]);
  const flags = (settings['public.flags.platforms'] ?? {}) as Partial<Record<Platform, boolean>>;
  const global = (rules ?? []).find((r) => r.scope === 'global');
  // api.organizations tidak membuka fee_rule_id: rule org yang terlihat hanya pasti milik org ini kalau user cuma melihat satu org.
  const orgRules = (rules ?? []).filter((r) => r.scope === 'org');
  const fee = orgRules.length === 1 && orgCount === 1 ? orgRules[0] : global;
  return {
    mode: 'brand',
    org: { id: org.id, name: org.name, status: org.status ?? 'pending_verification' },
    categories: (categories ?? []).flatMap((c) => (c.id ? [{ id: c.id, name_id: c.name_id ?? '', name_en: c.name_en ?? c.name_id ?? '' }] : [])),
    rewardTypes: (rewardTypes ?? []).flatMap((r) =>
      r.id && r.code
        ? [{
            id: r.id,
            code: r.code,
            name: r.name ?? r.code,
            unit_label: r.unit_label ?? '',
            kind: r.kind ?? 'custom',
            idr_value_per_unit: num(r.idr_value_per_unit),
            decimals: r.decimals ?? 0,
            owner_org_id: r.owner_org_id,
          }]
        : [],
    ),
    platforms: Object.fromEntries(PLATFORMS.map((p) => [p, flags[p] === true])) as Record<Platform, boolean>,
    fee: { mgmt_fee_pct: num(fee?.mgmt_fee_pct, 15), admin_fee_pct: num(fee?.admin_fee_pct, 5) },
    taxPct: num(settings['public.billing.tax_pct'], 11),
    managedServiceIdr: num(settings['public.billing.managed_service_idr'], 2_500_000),
  };
}
