// Teks detail campaign (F-C04) dari api.campaign_detail: rate per rule, cap efektif per platform, tag wajib, syarat.
// Murni (t diberikan pemanggil) — dipakai halaman detail web dan app native supaya kalimatnya identik.
import { formatCompact, formatNumber, type UiLocale } from '@clipper/ui/format';
import { platformLabels, type Platform } from '@clipper/ui/platform-paths';
import { arr, num, type RateRule } from './pure';
import { formatAmount } from './units';
import type { CampaignDetail } from './detail';

type T = (key: string, values?: Record<string, string | number>) => string;

export function detailText(d: CampaignDetail, platforms: Platform[], terms: Record<string, { cap_pct: number; hold_days: number }>, locale: UiLocale, t: T) {
  const c = d.campaign;
  // Cap efektif = max_per_clip pool × ketentuan Trust Score & platform clipper ini (sama dengan accrual).
  const capText = (p: (typeof d.pools)[number]) => {
    const by = new Map<number, Platform[]>();
    for (const pf of platforms) {
      const v = (num(p.max_per_clip) * num(terms[pf]?.cap_pct ?? 100)) / 100;
      by.set(v, [...(by.get(v) ?? []), pf]);
    }
    return [...by]
      .map(([v, pfs]) => (by.size > 1 ? `${formatAmount(v, p, locale)} (${pfs.map((x) => platformLabels[x]).join(', ')})` : formatAmount(v, p, locale)))
      .join(' · ');
  };
  const amount = (r: RateRule, v: unknown) =>
    formatAmount(num(v), { code: r.code ?? 'IDR', unit_label: r.unit_label ?? '', decimals: r.decimals ?? 0 }, locale);
  const describe = (r: RateRule): string[] => {
    if (r.kind === 'per_1k_views') return [t('detail.rate.per1k', { amount: amount(r, r.params.rate) })];
    if (r.kind === 'flat_per_post') return [t('detail.rate.flat', { amount: amount(r, r.params.amount) })];
    if (r.kind === 'milestone_bonus')
      return [t('detail.rate.milestone', { amount: amount(r, r.params.amount), views: formatNumber(num(r.params.threshold), locale) })];
    if (r.kind === 'tiered_cpm')
      return arr<Record<string, unknown>>(r.params.tiers).map((tier) =>
        t('detail.rate.tier', {
          from: formatCompact(num(tier.from), locale),
          to: tier.to == null ? '∞' : formatCompact(num(tier.to), locale),
          amount: amount(r, tier.rate),
        }),
      );
    return [];
  };
  const rateGroups = [null, ...platforms]
    .map((p) => ({ platform: p, rules: d.rules.filter((r) => r.platform === p) }))
    .filter((g) => g.rules.length);
  const tags = [...c.required_hashtags.map((h) => `#${h}`), ...c.required_mentions.map((m) => `@${m}`), ...c.required_links];
  const requirements = [
    c.min_duration_sec || c.max_duration_sec
      ? t('detail.req.duration', { min: c.min_duration_sec ?? 0, max: c.max_duration_sec ?? '∞' })
      : null,
    c.min_followers ? t('detail.req.followers', { n: formatNumber(c.min_followers, locale) }) : null,
    c.min_account_age_days ? t('detail.req.accountAge', { n: c.min_account_age_days }) : null,
    c.min_trust_score ? t('detail.req.trust', { n: c.min_trust_score }) : null,
    c.kyc_required ? t('detail.req.kyc') : null,
    c.min_views ? t('detail.req.minViews', { n: formatNumber(c.min_views, locale) }) : null,
    t('detail.req.maxClips', { n: c.max_clips_per_clipper, used: d.my.clips_used }),
    c.clipper_quota ? t('detail.req.quota', { n: formatNumber(c.clipper_quota, locale) }) : null,
    t(`detail.req.review.${c.review_mode === 'auto' ? 'auto' : 'manual'}`),
  ].filter((x): x is string => !!x);
  return { capText, describe, rateGroups, tags, requirements };
}
