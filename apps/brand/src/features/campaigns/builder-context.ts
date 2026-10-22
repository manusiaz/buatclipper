import { PLATFORMS, type BuilderContext, type Platform } from '@clipper/campaign-builder';
import { num, publicSettings, type OrgContext } from '@/lib/org';

/**
 * Konteks builder (F-B02) dari api: kategori, reward type global + org, flag platform, pajak, paket managed, dan fee efektif
 * dengan urutan sama seperti finance.effective_fee_rule: rule campaign → rule org → global.
 */
export async function builderContext(
  { core, org }: Pick<OrgContext, 'core' | 'org'>,
  campaignFeeRuleId: string | null = null,
): Promise<BuilderContext> {
  // fee org milik admin (kolom admin di replika org core), bukan data org di project brand
  const { data: feeOrg } = await core.from('organizations').select('fee_rule_id').eq('id', org.id).maybeSingle();
  const orgRule = feeOrg?.fee_rule_id ?? null;
  const ruleIds = [campaignFeeRuleId, orgRule].filter((x): x is string => !!x);
  const [{ data: categories }, { data: rewardTypes }, { data: rules }, settings] = await Promise.all([
    core.from('categories').select('id, name_id, name_en, sort').eq('active', true).order('sort'),
    core
      .from('reward_types')
      .select('id, code, name, unit_label, kind, idr_value_per_unit, decimals, owner_org_id')
      .or(`owner_org_id.is.null,owner_org_id.eq.${org.id}`)
      .order('code'),
    core
      .from('fee_rules')
      .select('id, scope, mgmt_fee_pct, admin_fee_pct')
      .or(ruleIds.length ? `scope.eq.global,id.in.(${ruleIds.join(',')})` : 'scope.eq.global'),
    publicSettings(core, ['public.flags.platforms', 'public.billing.tax_pct', 'public.billing.managed_service_idr']),
  ]);
  const flags = (settings['public.flags.platforms'] ?? {}) as Partial<Record<Platform, boolean>>;
  const byId = (id: string | null | undefined) => (id ? (rules ?? []).find((r) => r.id === id) : undefined);
  const fee = byId(campaignFeeRuleId) ?? byId(orgRule) ?? (rules ?? []).find((r) => r.scope === 'global');
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
