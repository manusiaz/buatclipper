import { cache } from 'react';
import { unstable_cache } from 'next/cache';
import type { CoreView } from '@clipper/db-core';
import type { Platform } from '@clipper/ui';
import { core, deadline } from '@/lib/core';
import { rulesFromJson, type Rule } from '@/lib/rates';
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
  coverPath: string | null;
  rules: Rule[];
  pools: Pool[];
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

/** F-X02: campaign publik (RLS anon: tayang, visibility public, bukan template) + rule aktif, pool, cover. */
async function load(slug: string): Promise<PublicCampaign | null> {
  const { data, error } = await core.from('campaigns').select(COLUMNS).eq('slug', slug).abortSignal(deadline()).maybeSingle();
  if (error) throw new Error(error.message);
  const c = data as unknown as Row | null;
  if (!c?.id || !c.slug || !c.title || !c.status) return null;

  const [rules, pools, cover] = await Promise.all([
    core.from('rate_rules').select('kind, platform, params, reward_type_id, pool_id, effective_from, effective_to').eq('campaign_id', c.id).abortSignal(deadline()),
    core.from('reward_pools').select('id, reward_type_id, total, allocated, remaining').eq('campaign_id', c.id).abortSignal(deadline()),
    core.from('campaign_assets').select('storage_path').eq('campaign_id', c.id).eq('kind', 'cover').order('created_at').limit(1).abortSignal(deadline()),
  ]);
  const failed = rules.error ?? pools.error ?? cover.error;
  if (failed) throw new Error(failed.message);

  const now = Date.now();
  const active = (rules.data ?? []).filter(
    (r) => r.effective_from && Date.parse(r.effective_from) <= now && (!r.effective_to || Date.parse(r.effective_to) > now),
  );
  const typeIds = [...new Set([...active, ...(pools.data ?? [])].map((x) => x.reward_type_id).filter((x): x is string => !!x))];
  const types = typeIds.length
    ? await core.from('reward_types').select('id, code, unit_label, decimals').in('id', typeIds).abortSignal(deadline())
    : { data: [], error: null };
  if (types.error) throw new Error(types.error.message);
  const typeOf = (id: string | null) => types.data?.find((t) => t.id === id);

  return {
    campaign: { ...c, id: c.id, slug: c.slug, title: c.title, status: c.status, platforms: c.platforms ?? [] },
    faq: faqOf(c.faq),
    coverPath: cover.data?.[0]?.storage_path ?? null,
    rules: rulesFromJson(active.map((r) => ({ ...r, ...typeOf(r.reward_type_id) }))),
    pools: (pools.data ?? [])
      .filter((p): p is typeof p & { id: string } => !!p.id)
      .map((p) => {
        const t = typeOf(p.reward_type_id);
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
