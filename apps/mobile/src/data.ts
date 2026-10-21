// Data app native = query yang sama dengan halaman app.{domain} (RLS core = user ini). Hitungan murni dipakai bersama
// lewat @clipper/clipper-lib (dipakai juga app clipper web) supaya angka di HP = angka di web.
import { useCallback, useEffect, useRef, useState } from 'react';
import { budgetUsedRatio, cardRates, isPlatform, maxViews, num, type RateRule } from '@clipper/clipper-lib/pure';
import { parseDetail, type CampaignDetail } from '@clipper/clipper-lib/detail';
import { toRpcFilters, type CampaignFilters } from '@clipper/clipper-lib/filters';
import { earningsBySubmission, type EarningRow } from '@clipper/clipper-lib/units';
import type { Platform } from '@clipper/ui/platform-paths';
import { core, invoke, publicUrl } from './supabase';

export type Loaded<T> = { data: T | null; error: string | null; loading: boolean; reload: () => Promise<void> };

/** Muat data async + muat ulang (tarik layar / sesudah aksi). Hasil basi dari pemanggilan lama diabaikan. */
export function useLoad<T>(fn: () => Promise<T>, deps: unknown[]): Loaded<T> {
  const [state, setState] = useState<{ data: T | null; error: string | null; loading: boolean }>({ data: null, error: null, loading: true });
  const seq = useRef(0);
  const run = useCallback(async () => {
    const id = ++seq.current;
    setState((s) => ({ ...s, loading: true }));
    try {
      const data = await fn();
      if (id === seq.current) setState({ data, error: null, loading: false });
    } catch (e) {
      if (id === seq.current) setState((s) => ({ data: s.data, error: e instanceof Error ? e.message : String(e), loading: false }));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  useEffect(() => {
    void run();
  }, [run]);
  return { ...state, reload: run };
}

const must = <T,>(r: { data: T | null; error: { message: string } | null }): T => {
  if (r.error) throw new Error(r.error.message);
  return r.data as T;
};

export interface RewardUnit {
  id: string;
  code: string;
  name: string;
  unit_label: string;
  decimals: number;
  idr_value_per_unit: number;
}

export async function rewardTypes(ids: Iterable<string | null | undefined>): Promise<Map<string, RewardUnit>> {
  const list = [...new Set(ids)].filter((x): x is string => !!x);
  if (!list.length) return new Map();
  const rows = must(await core.from('reward_types').select('id,code,name,unit_label,decimals,idr_value_per_unit').in('id', list)) ?? [];
  return new Map(
    rows.map((r) => [
      r.id!,
      { id: r.id!, code: r.code ?? '', name: r.name ?? '', unit_label: r.unit_label ?? '', decimals: r.decimals ?? 0, idr_value_per_unit: Number(r.idr_value_per_unit ?? 0) },
    ]),
  );
}

export async function categories(locale: 'id' | 'en'): Promise<Map<string, string>> {
  const rows = must(await core.from('categories').select('id,name_id,name_en,sort,active').eq('active', true).order('sort')) ?? [];
  return new Map(rows.map((c) => [c.id ?? '', (locale === 'en' ? c.name_en : c.name_id) ?? c.id ?? '']));
}

export async function settings(keys: string[]): Promise<Record<string, unknown>> {
  const rows = must(await core.from('settings').select('key,value').in('key', keys)) ?? [];
  return Object.fromEntries(rows.map((r) => [r.key, r.value]));
}

// ── Campaign (F-C03): api.list_campaigns + kartu (cards.ts toCards) ──
export interface CardData {
  id: string;
  title: string;
  brand?: { name: string; verified: boolean };
  coverSrc: string | null;
  category?: string;
  platforms: Platform[];
  rates: { platform: Platform; ratePer1k: number }[];
  pinned: boolean;
  isNew: boolean;
  deadline?: string;
  remainingViews?: number;
  budgetUsedRatio?: number;
  ctaState?: string;
  ctaReason?: string | null;
  claimExpiresAt?: string;
}

export const PAGE_SIZE = 12;

export async function campaignPage(uid: string, filters: CampaignFilters, cursor: string | null, locale: 'id' | 'en'): Promise<{ items: CardData[]; next: string | null }> {
  const rows =
    must(
      await core.rpc('list_campaigns', {
        p_filters: toRpcFilters(filters, PAGE_SIZE) as never,
        ...(cursor ? { p_cursor: cursor } : {}),
      }),
    ) ?? [];
  const rules = rows.flatMap((r) => (Array.isArray(r.rates) ? (r.rates as unknown as RateRule[]) : []));
  const claimed = rows.filter((r) => r.cta_state === 'claimed_not_submitted').map((r) => r.id);
  const [units, cats, open] = await Promise.all([
    rewardTypes(rules.map((r) => r.reward_type_id)),
    categories(locale),
    claimed.length ? core.from('claims').select('campaign_id,expires_at').eq('user_id', uid).eq('status', 'open').in('campaign_id', claimed) : Promise.resolve({ data: [] as { campaign_id: string | null; expires_at: string | null }[] }),
  ]);
  const idr = new Map([...units.values()].map((u) => [u.id, u.idr_value_per_unit]));
  const expiry = new Map((open.data ?? []).map((c) => [c.campaign_id, c.expires_at]));
  const items = rows.map((r) => {
    const platforms = (r.platforms ?? []).filter(isPlatform) as Platform[];
    return {
      id: r.id,
      title: r.title,
      brand: r.brand_name ? { name: r.brand_name, verified: !!r.brand_verified } : undefined,
      coverSrc: publicUrl('campaign-covers', r.cover_path),
      category: r.category_id ? cats.get(r.category_id) : undefined,
      platforms,
      rates: cardRates(Array.isArray(r.rates) ? (r.rates as unknown as RateRule[]) : [], platforms, idr) as { platform: Platform; ratePer1k: number }[],
      pinned: !!r.is_pinned,
      isNew: !!r.is_new,
      deadline: r.submit_deadline ?? undefined,
      remainingViews: maxViews(r.est_remaining_views),
      budgetUsedRatio: budgetUsedRatio(r.budget_idr, r.remaining_idr),
      ctaState: r.cta_state ?? undefined,
      ctaReason: r.cta_reason,
      claimExpiresAt: expiry.get(r.id) ?? undefined,
    } satisfies CardData;
  });
  const last = rows.at(-1);
  return { items, next: rows.length === PAGE_SIZE && last?.next_cursor ? last.next_cursor : null };
}

export async function verifiedAccounts(uid: string): Promise<number> {
  const r = await core.from('social_accounts').select('id', { count: 'exact', head: true }).eq('user_id', uid).eq('status', 'verified');
  if (r.error) throw new Error(r.error.message);
  return r.count ?? 0;
}

// ── Detail (F-C04–C06): api.campaign_detail + akun sosmed + ketentuan cap/hold ──
export interface DetailData {
  d: CampaignDetail;
  coverSrc: string | null;
  accounts: { id: string; platform: Platform; handle: string; status: string }[];
  terms: Record<string, { cap_pct: number; hold_days: number }>;
  assetUrls: Map<string, string>;
}

export async function campaignDetail(uid: string, id: string): Promise<DetailData> {
  const d = parseDetail(must(await core.rpc('campaign_detail', { p_campaign: id })));
  const platforms = d.campaign.platforms.filter(isPlatform) as Platform[];
  const files = d.assets.filter((a) => a.kind !== 'cover');
  const privatePaths = files.filter((a) => a.storage_path && a.bucket === 'campaign-assets').map((a) => a.storage_path!);
  const [social, signed, terms] = await Promise.all([
    core.from('social_accounts').select('id,platform,handle,status').eq('user_id', uid).in('platform', platforms).neq('status', 'disconnected'),
    privatePaths.length ? core.storage.from('campaign-assets').createSignedUrls(privatePaths, 3600) : Promise.resolve({ data: [] as { path: string | null; signedUrl: string }[] }),
    core.rpc('my_clip_terms'),
  ]);
  const cover = d.assets.find((a) => a.kind === 'cover' && a.storage_path);
  return {
    d,
    coverSrc: publicUrl('campaign-covers', cover?.storage_path),
    accounts: (social.data ?? []).filter((a) => isPlatform(a.platform)).map((a) => ({ id: a.id ?? '', platform: a.platform as Platform, handle: a.handle ?? '', status: a.status ?? '' })),
    terms: terms.data && typeof terms.data === 'object' && !Array.isArray(terms.data) ? (terms.data as DetailData['terms']) : {},
    assetUrls: new Map((signed.data ?? []).flatMap((s) => (s.path && s.signedUrl ? [[s.path, s.signedUrl] as const] : []))),
  };
}

export async function claimCampaign(id: string): Promise<{ ok: true } | { ok: false; code: string }> {
  const { error } = await core.rpc('claim_campaign', { p_campaign: id });
  return error ? { ok: false, code: error.message } : { ok: true };
}

// ── Submit (F-C06): Edge Function core/social (list_videos / submit), sama dengan Server Action web ──
export interface VideoItem {
  postId: string;
  url: string;
  caption: string;
  postedAt: string;
  durationSec: number | null;
  thumbnail: string | null;
  missingTags: string[];
}

const https = (v: unknown) => (typeof v === 'string' && /^https:\/\//.test(v) ? v : null);

export async function listVideos(accountId: string, claimId: string) {
  const r = await invoke<{ videos: (Omit<VideoItem, 'missingTags'> & { missing_tags: string[] | null })[] }>('core', 'social', {
    action: 'list_videos',
    account_id: accountId,
    claim_id: claimId,
  });
  if (!r.ok) return r;
  return {
    ok: true as const,
    data: (r.data.videos ?? []).slice(0, 60).map((v) => ({
      postId: String(v.postId),
      url: https(v.url) ?? '',
      caption: String(v.caption ?? ''),
      postedAt: String(v.postedAt ?? ''),
      durationSec: typeof v.durationSec === 'number' ? v.durationSec : null,
      thumbnail: https(v.thumbnail),
      missingTags: Array.isArray(v.missing_tags) ? v.missing_tags.map(String) : [],
    })),
  };
}

export function submitVideo(input: { claimId: string; accountId: string; postId?: string; url?: string }) {
  return invoke<{ submission_id: string; status: string }>('core', 'social', {
    action: 'submit',
    claim_id: input.claimId,
    account_id: input.accountId,
    ...(input.postId ? { post_id: input.postId } : { url: input.url }),
  });
}

// ── Tugas (F-C07) ──
export async function tasks(uid: string) {
  const now = new Date().toISOString();
  const [claims, subs] = await Promise.all([
    core.from('claims').select('id,campaign_id,expires_at').eq('user_id', uid).eq('status', 'open').gt('expires_at', now).order('expires_at'),
    core
      .from('submissions')
      .select('id,campaign_id,platform,url,status,counted_views,last_views,last_snapshot_at,created_at')
      .eq('user_id', uid)
      .order('created_at', { ascending: false })
      .limit(100),
  ]);
  const list = must(subs) ?? [];
  const open = must(claims) ?? [];
  const ids = [...new Set([...list.map((s) => s.campaign_id!), ...open.map((c) => c.campaign_id!)])].filter(Boolean);
  const [campaigns, earnings] = await Promise.all([
    ids.length ? core.from('campaigns').select('id,title').in('id', ids) : Promise.resolve({ data: [] as { id: string | null; title: string | null }[] }),
    list.length ? core.from('clip_earnings').select('submission_id,pool_id,amount,released_at').in('submission_id', list.map((s) => s.id!)) : Promise.resolve({ data: [] as EarningRow[] }),
  ]);
  const title = new Map((campaigns.data ?? []).map((c) => [c.id, c.title ?? '']));
  const poolIds = [...new Set((earnings.data ?? []).map((e) => e.pool_id))].filter((x): x is string => !!x);
  const pools = poolIds.length ? must(await core.from('reward_pools').select('id,reward_type_id').in('id', poolIds)) ?? [] : [];
  const units = await rewardTypes(pools.map((p) => p.reward_type_id));
  const earned = earningsBySubmission(earnings.data ?? [], new Map(pools.map((p) => [p.id, units.get(p.reward_type_id ?? '')])));
  return {
    claims: open.map((c) => ({ id: c.id!, campaignId: c.campaign_id!, expiresAt: c.expires_at!, title: title.get(c.campaign_id) ?? '' })),
    submissions: list.map((s) => ({
      id: s.id!,
      campaignId: s.campaign_id!,
      title: title.get(s.campaign_id) ?? '',
      platform: (isPlatform(s.platform) ? s.platform : null) as Platform | null,
      url: s.url ?? '',
      status: s.status ?? '',
      views: num(s.last_views ?? s.counted_views),
      counted: s.last_views != null && num(s.last_views) !== num(s.counted_views) ? num(s.counted_views) : null,
      updatedAt: s.last_snapshot_at ?? s.created_at ?? null,
      earned: earned(s.id!),
    })),
  };
}

// ── Wallet (F-C08): wallet_balances per state + riwayat (cermin release disembunyikan, sama dengan web) ──
export async function wallet(uid: string) {
  const [bal, idrRow, entries, set] = await Promise.all([
    core.from('wallet_balances').select('reward_type_id,state,amount').eq('user_id', uid),
    core.from('reward_types').select('id').eq('code', 'IDR').is('owner_org_id', null).maybeSingle(),
    core.from('wallet_entries').select('id,reward_type_id,amount,state,ref_type,created_at').eq('user_id', uid).order('created_at', { ascending: false }).limit(60),
    settings(['public.finance.min_withdraw_idr']),
  ]);
  const rows = must(bal) ?? [];
  const idrId = idrRow.data?.id ?? null;
  const units = await rewardTypes([...rows.map((r) => r.reward_type_id), ...(must(entries) ?? []).map((e) => e.reward_type_id), idrId]);
  const sum = (state: string, unit: string | null) => rows.filter((r) => r.state === state && r.reward_type_id === unit).reduce((a, r) => a + num(r.amount), 0);
  const others = [...units.values()]
    .filter((u) => u.id !== idrId)
    .map((u) => ({ unit: u, pending: sum('pending', u.id), available: sum('available', u.id), withdrawn: sum('withdrawn', u.id) }))
    .filter((b) => b.pending || b.available || b.withdrawn);
  return {
    idr: { pending: sum('pending', idrId), available: sum('available', idrId), withdrawn: sum('withdrawn', idrId) },
    others,
    min: num(set['public.finance.min_withdraw_idr']) || 100_000,
    units,
    history: (must(entries) ?? []).filter((e) => e.state !== 'withdrawn' && !(e.ref_type === 'release' && num(e.amount) < 0)),
  };
}

// ── Notifikasi (F-C11) & header ──
export async function notifications(uid: string) {
  return must(await core.from('notifications').select('id,event,payload,read_at,created_at').eq('user_id', uid).order('created_at', { ascending: false }).limit(100)) ?? [];
}

export async function markRead(uid: string, id?: number) {
  const q = core.from('notifications').update({ read_at: new Date().toISOString() }).eq('user_id', uid).is('read_at', null);
  await (id ? q.eq('id', id) : q);
}

export async function chrome(uid: string) {
  const [unread, profile, social] = await Promise.all([
    core.from('notifications').select('id', { count: 'exact', head: true }).eq('user_id', uid).is('read_at', null),
    core.from('my_profile').select('username,display_name,avatar_path').maybeSingle(),
    core.from('social_accounts').select('status').eq('user_id', uid),
  ]);
  return {
    unread: unread.count ?? 0,
    profile: profile.data,
    avatar: publicUrl('avatars', profile.data?.avatar_path),
    // Sama dengan features/shell/chrome.ts: belum ada akun terverifikasi atau ada token kedaluwarsa/dicabut.
    socialAttention: ((st) => !st.includes('verified') || st.some((s) => s === 'token_expired' || s === 'revoked'))((social.data ?? []).map((s) => s.status)),
  };
}

export async function socialAccounts(uid: string) {
  const [accounts, set] = await Promise.all([
    core.from('social_accounts').select('id,platform,handle,status,followers,verified_at').eq('user_id', uid).neq('status', 'disconnected').order('created_at'),
    settings(['public.flags.platforms', 'public.market.max_accounts_per_platform']),
  ]);
  return {
    accounts: (must(accounts) ?? []).filter((a) => isPlatform(a.platform)).map((a) => ({ ...a, platform: a.platform as Platform })),
    flags: set['public.flags.platforms'],
    max: num(set['public.market.max_accounts_per_platform']) || 3,
  };
}

/** Konteks sheet Submit: akun sosmed user di platform campaign (sama dengan DetailCta web). */
export async function submitContext(uid: string, campaignId: string) {
  const { data: camp, error } = await core.from('campaigns').select('platforms').eq('id', campaignId).maybeSingle();
  if (error) throw new Error(error.message);
  const platforms = (camp?.platforms ?? []).filter(isPlatform) as Platform[];
  const rows = platforms.length
    ? must(await core.from('social_accounts').select('id,platform,handle,status').eq('user_id', uid).in('platform', platforms).neq('status', 'disconnected')) ?? []
    : [];
  return rows.filter((a) => isPlatform(a.platform)).map((a) => ({ id: a.id ?? '', platform: a.platform as Platform, handle: a.handle ?? '', status: a.status ?? '' }));
}

/** /share: claim terbuka user + judul campaign (sama dengan app/share web). */
export async function openClaims(uid: string) {
  const open = must(await core.from('claims').select('id,campaign_id,expires_at').eq('user_id', uid).eq('status', 'open').gt('expires_at', new Date().toISOString()).order('expires_at')) ?? [];
  const titles = open.length ? must(await core.from('campaigns').select('id,title').in('id', open.map((c) => c.campaign_id!))) ?? [] : [];
  const title = new Map(titles.map((c) => [c.id, c.title ?? '']));
  return open.map((c) => ({ id: c.id!, campaignId: c.campaign_id!, expiresAt: c.expires_at!, title: title.get(c.campaign_id) ?? '' }));
}
