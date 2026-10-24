import { cache } from 'react';
import { unstable_cache } from 'next/cache';
import type { CoreView } from '@clipper/db-core';
import type { Platform } from '@clipper/ui';
import { core, deadline } from '@/lib/core';
import { maxViews, rulesFromJson, type Rule } from '@/lib/rates';
import { num } from '@/lib/settings';

export const SLUG_RE = /^[a-z0-9-]{3,80}$/;

type Row = CoreView<'campaigns'>;

export interface Pool {
  id: string;
  code: string | null;
  unit_label: string | null;
  decimals: number | null;
  total: number;
  allocated: number;
  remaining: number;
}

export interface PublicCampaign {
  campaign: Row & { id: string; slug: string; title: string; status: NonNullable<Row['status']>; platforms: Platform[] };
  faq: Array<{ q: string; a: string }>;
  brand: { name: string; verified: boolean } | null;
  coverPath: string | null;
  rules: Rule[];
  pools: Pool[];
  /** est_remaining_views api.list_campaigns (sama dengan kartu landing & app). */
  viewsLeft: number | null;
}

const COLUMNS =
  'id, slug, title, type, category_id, status, platforms, brief, required_hashtags, required_mentions, required_links, ' +
  'sponsored_label, min_duration_sec, max_duration_sec, dos, donts, example_urls, faq, start_at, submit_deadline, ' +
  'view_window_days, min_followers, min_account_age_days, kyc_required, min_views, max_clips_per_clipper, created_at';

function faqOf(json: unknown): Array<{ q: string; a: string }> {
  if (!Array.isArray(json)) return [];
  return json
    .map((x) => (x && typeof x === 'object' ? (x as Record<string, unknown>) : {}))
    .map((x) => ({ q: typeof x.q === 'string' ? x.q.trim() : '', a: typeof x.a === 'string' ? x.a.trim() : '' }))
    .filter((x) => x.q !== '' && x.a !== '');
}

/**
 * F-X02: brief dari view api.campaigns (RLS anon: tayang, visibility public, bukan template); brand, cover, rule aktif, dan
 * estimasi sisa views dari api.list_campaigns (filter slug persis); pool per reward type dari api.reward_pools.
 */
async function load(slug: string): Promise<PublicCampaign | null> {
  const [view, list] = await Promise.all([
    core.from('campaigns').select(COLUMNS).eq('slug', slug).abortSignal(deadline()).maybeSingle(),
    core.rpc('list_campaigns', { p_filters: { slug, status: 'all', limit: 1 } }).abortSignal(deadline()),
  ]);
  const failed = view.error ?? list.error;
  if (failed) throw new Error(failed.message);
  const c = view.data as unknown as Row | null;
  if (!c?.id || !c.slug || !c.title || !c.status) return null;
  const card = list.data?.find((x) => x.id === c.id);
  const rules = rulesFromJson(card?.rates);

  const pools = await core.from('reward_pools').select('id, reward_type_id, total, allocated, remaining').eq('campaign_id', c.id).abortSignal(deadline());
  if (pools.error) throw new Error(pools.error.message);
  // Unit reward type biasanya sudah ada di rates; reward_types hanya untuk pool tanpa rule aktif.
  const known = new Map(rules.filter((r) => r.reward_type_id).map((r) => [r.reward_type_id!, r as Pick<Rule, 'code' | 'unit_label' | 'decimals'>]));
  const missing = [...new Set((pools.data ?? []).map((p) => p.reward_type_id).filter((x): x is string => !!x && !known.has(x)))];
  if (missing.length) {
    const types = await core.from('reward_types').select('id, code, unit_label, decimals').in('id', missing).abortSignal(deadline());
    if (types.error) throw new Error(types.error.message);
    for (const t of types.data ?? []) if (t.id) known.set(t.id, { code: t.code, unit_label: t.unit_label, decimals: t.decimals });
  }

  return {
    campaign: { ...c, id: c.id, slug: c.slug, title: c.title, status: c.status, platforms: c.platforms ?? [] },
    faq: faqOf(c.faq),
    brand: card?.brand_name ? { name: card.brand_name, verified: !!card.brand_verified } : null,
    coverPath: card?.cover_path ?? null,
    rules,
    viewsLeft: maxViews(card?.est_remaining_views),
    pools: (pools.data ?? [])
      .filter((p): p is typeof p & { id: string } => !!p.id)
      .map((p) => {
        const t = p.reward_type_id ? known.get(p.reward_type_id) : undefined;
        return {
          id: p.id,
          code: t?.code ?? null,
          unit_label: t?.unit_label ?? null,
          decimals: t?.decimals ?? null,
          total: num(p.total) ?? 0,
          allocated: num(p.allocated) ?? 0,
          remaining: num(p.remaining) ?? 0,
        };
      }),
  };
}

const loadCached = unstable_cache(load, ['web:campaign'], { revalidate: 60 });

/** Satu fetch per request untuk page, generateMetadata, dan opengraph-image; slug tidak valid → null (404). */
export const getPublicCampaign = cache((slug: string) => (SLUG_RE.test(slug) ? loadCached(slug) : Promise.resolve(null)));

/** sitemap.ts: slug campaign live publik. */
export const getLiveSlugs = unstable_cache(
  async (): Promise<Array<{ slug: string; updated: string | null }>> => {
    const { data, error } = await core
      .from('campaigns')
      .select('slug, start_at, created_at')
      .eq('status', 'live')
      .order('start_at', { ascending: false })
      .limit(5000)
      .abortSignal(deadline());
    if (error) throw new Error(error.message);
    return (data ?? []).filter((c) => !!c.slug).map((c) => ({ slug: c.slug!, updated: c.start_at ?? c.created_at }));
  },
  ['web:live-slugs'],
  { revalidate: 3600 },
);
