// api.list_campaigns → props CampaignCard (dipakai halaman & aksi "muat lagi").
import { getTranslations } from 'next-intl/server';
import { getAuth } from '@clipper/auth/server';
import type { CampaignCtaState, IconName, Platform } from '@clipper/ui';
import type { CoreFn } from '@clipper/db-core';
import { budgetUsedRatio, cardRates, categoryIcon, isPlatform, maxViews, type RateRule } from '@clipper/clipper-lib/pure';
import { core, errorText, publicUrl, rewardTypes, uiLocale } from '../lib/server';
import { fixFor } from './fix';
import { toRpcFilters, type CampaignFilters } from '@clipper/clipper-lib/filters';

export const PAGE_SIZE = 12;

export interface CampaignCardData {
  id: string;
  title: string;
  brand?: { name: string; verified: boolean };
  coverSrc: string | null;
  category?: string;
  categoryIcon: IconName;
  platforms: Platform[];
  rates: { platform: Platform; ratePer1k: number }[];
  pinned: boolean;
  isNew: boolean;
  status: string;
  statusLabel: string;
  deadline?: string;
  remainingViews?: number;
  budgetUsedRatio?: number;
  ctaState?: CampaignCtaState;
  ctaHref?: string;
  ctaReason?: string;
  ctaAction?: { label: string; href: string };
  claimExpiresAt?: string;
}

type Row = CoreFn<'list_campaigns'>['Returns'][number];
type RpcFilters = CoreFn<'list_campaigns'>['Args']['p_filters'];

export async function categoryNames(): Promise<Map<string, string>> {
  const [db, locale] = await Promise.all([core(), uiLocale()]);
  const { data } = await db.from('categories').select('id,name_id,name_en,sort,active').eq('active', true).order('sort');
  return new Map((data ?? []).map((c) => [c.id ?? '', (locale === 'en' ? c.name_en : c.name_id) ?? c.id ?? '']));
}

export async function fetchCampaignPage(
  filters: CampaignFilters,
  cursor: string | null,
): Promise<{ ok: true; items: CampaignCardData[]; next: string | null } | { ok: false; message: string }> {
  const db = await core();
  const { data, error } = await db.rpc('list_campaigns', {
    p_filters: toRpcFilters(filters, PAGE_SIZE) as RpcFilters,
    ...(cursor ? { p_cursor: cursor } : {}),
  });
  if (error) return { ok: false, message: await errorText(error.message) };
  const rows = data ?? [];
  const items = await toCards(rows);
  const last = rows.at(-1);
  return { ok: true, items, next: rows.length === PAGE_SIZE && last?.next_cursor ? last.next_cursor : null };
}

export async function toCards(rows: Row[]): Promise<CampaignCardData[]> {
  if (!rows.length) return [];
  const { claims } = await getAuth('sso');
  const db = await core();
  const rules = rows.flatMap((r) => (Array.isArray(r.rates) ? (r.rates as unknown as RateRule[]) : []));
  const claimed = rows.filter((r) => r.cta_state === 'claimed_not_submitted').map((r) => r.id);
  const [units, categories, open, t] = await Promise.all([
    rewardTypes(rules.map((r) => r.reward_type_id)),
    categoryNames(),
    claimed.length && claims
      ? db.from('claims').select('campaign_id,expires_at').eq('user_id', claims.sub).eq('status', 'open').in('campaign_id', claimed)
      : Promise.resolve({ data: [] as { campaign_id: string | null; expires_at: string | null }[] }),
    getTranslations('clipper'),
  ]);
  const idr = new Map([...units.values()].map((u) => [u.id, u.idr_value_per_unit]));
  const expiry = new Map((open.data ?? []).map((c) => [c.campaign_id, c.expires_at]));

  return Promise.all(
    rows.map(async (r) => {
      const platforms = (r.platforms ?? []).filter(isPlatform) as Platform[];
      const state = (r.cta_state ?? undefined) as CampaignCtaState | undefined;
      const fix = state === 'not_eligible' ? fixFor(r.cta_reason, r.id) : null;
      const href = `/campaigns/${r.id}`;
      return {
        id: r.id,
        title: r.title,
        brand: r.brand_name ? { name: r.brand_name, verified: !!r.brand_verified } : undefined,
        coverSrc: publicUrl('campaign-covers', r.cover_path),
        category: r.category_id ? categories.get(r.category_id) ?? undefined : undefined,
        categoryIcon: categoryIcon(r.category_id),
        platforms,
        rates: cardRates(Array.isArray(r.rates) ? (r.rates as unknown as RateRule[]) : [], platforms, idr) as {
          platform: Platform;
          ratePer1k: number;
        }[],
        pinned: !!r.is_pinned,
        isNew: !!r.is_new,
        status: r.status,
        statusLabel: t(`status.campaign.${r.status}`),
        deadline: r.submit_deadline ?? undefined,
        remainingViews: maxViews(r.est_remaining_views),
        budgetUsedRatio: budgetUsedRatio(r.budget_idr, r.remaining_idr),
        ctaState: state,
        ctaHref: state === 'can_claim' ? href : state === 'claimed_not_submitted' ? `${href}?submit=1` : undefined,
        ctaReason: state === 'not_eligible' && r.cta_reason ? await errorText(`not_eligible:${r.cta_reason}`) : undefined,
        ctaAction: fix ? { label: t(`fix.${fix.key}`), href: fix.href } : undefined,
        claimExpiresAt: expiry.get(r.id) ?? undefined,
      } satisfies CampaignCardData;
    }),
  );
}
