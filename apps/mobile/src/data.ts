// Data app native = query yang sama dengan halaman app.{domain} (RLS core = user ini). Hitungan murni dipakai bersama
// lewat @clipper/clipper-lib (dipakai juga app clipper web) supaya angka di HP = angka di web.
import { useCallback, useEffect, useRef, useState } from 'react';
import { arr, budgetUsedRatio, cardRates, categoryIcon, communityLinks, estimateRelease, httpsUrl, isPlatform, isUuid, maxViews, num, trustEffects, weekStartUtc, type RateRule } from '@clipper/clipper-lib/pure';
import { parseDetail, type CampaignDetail } from '@clipper/clipper-lib/detail';
import { toRpcFilters, type CampaignFilters } from '@clipper/clipper-lib/filters';
import { earningsBySubmission, type EarningRow } from '@clipper/clipper-lib/units';
import type { Platform } from '@clipper/ui/platform-paths';
import { readCache, writeCache } from './cache';
import type { WidgetInput } from './widget-snapshot';
import { brandStorage, core, identityApi, invoke, publicUrl } from './supabase';

export type Loaded<T> = {
  data: T | null;
  error: string | null;
  loading: boolean;
  /** Waktu data terakhir berhasil dimuat (dari server atau cache). */
  updatedAt: number | null;
  /** Data yang tampil berasal dari cache karena muat ulang gagal. */
  stale: boolean;
  reload: () => Promise<void>;
};

/** Muat data async + muat ulang (tarik layar / sesudah aksi). Hasil basi dari pemanggilan lama diabaikan.
 * `cacheKey` (sertakan uid): tampilkan hasil terakhir dulu, simpan hasil baru, tetap tampil saat offline. */
export function useLoad<T>(fn: () => Promise<T>, deps: unknown[], cacheKey?: string): Loaded<T> {
  const [state, setState] = useState<{ data: T | null; error: string | null; loading: boolean; updatedAt: number | null; stale: boolean }>({
    data: null,
    error: null,
    loading: true,
    updatedAt: null,
    stale: false,
  });
  const seq = useRef(0);
  useEffect(() => {
    if (!cacheKey) return;
    let live = true;
    void readCache<T>(cacheKey).then((c) => {
      if (live && c) setState((s) => (s.data === null ? { ...s, data: c.data, updatedAt: c.at, stale: true } : s));
    });
    return () => {
      live = false;
    };
  }, [cacheKey]);
  const run = useCallback(async () => {
    const id = ++seq.current;
    setState((s) => ({ ...s, loading: true }));
    try {
      const data = await fn();
      if (id !== seq.current) return;
      setState({ data, error: null, loading: false, updatedAt: Date.now(), stale: false });
      if (cacheKey) void writeCache(cacheKey, data);
    } catch (e) {
      if (id === seq.current) setState((s) => ({ ...s, error: e instanceof Error ? e.message : String(e), loading: false, stale: s.data !== null }));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, cacheKey]);
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
  kind: string;
  unit_label: string;
  decimals: number;
  idr_value_per_unit: number;
  /** payout (Rupiah) | code_pool | webhook | manual_export. */
  fulfillment: string;
  recipient_schema: unknown;
}

export async function rewardTypes(ids: Iterable<string | null | undefined>): Promise<Map<string, RewardUnit>> {
  const list = [...new Set(ids)].filter((x): x is string => !!x);
  if (!list.length) return new Map();
  const rows = must(await core.from('reward_types').select('id,code,name,kind,unit_label,decimals,idr_value_per_unit,fulfillment,recipient_schema').in('id', list)) ?? [];
  return new Map(
    rows.map((r) => [
      r.id!,
      {
        id: r.id!,
        code: r.code ?? '',
        name: r.name ?? '',
        kind: r.kind ?? '',
        unit_label: r.unit_label ?? '',
        decimals: r.decimals ?? 0,
        idr_value_per_unit: Number(r.idr_value_per_unit ?? 0),
        fulfillment: r.fulfillment ?? 'payout',
        recipient_schema: r.recipient_schema ?? null,
      },
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
  categoryIcon: ReturnType<typeof categoryIcon>;
  status: string;
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
      categoryIcon: categoryIcon(r.category_id),
      status: r.status ?? 'live',
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
    privatePaths.length ? brandStorage.from('campaign-assets').createSignedUrls(privatePaths, 3600) : Promise.resolve({ data: [] as { path: string | null; signedUrl: string }[] }),
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
  if (!isUuid(id)) return { ok: false, code: 'bad_request' };
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
  if (!isUuid(accountId) || !isUuid(claimId)) return { ok: false as const, error: 'bad_request', status: 400 };
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

/** Validasi sama dengan server action submitVideo web: uuid, post_id ≤ 64, url https. */
export async function submitVideo(input: { claimId: string; accountId: string; postId?: string; url?: string }) {
  const postId = input.postId?.trim().slice(0, 64);
  const url = input.url ? httpsUrl(input.url.trim()) : null;
  if (!isUuid(input.claimId) || !isUuid(input.accountId)) return { ok: false as const, error: 'bad_request', status: 400 };
  if (!postId && !url) return { ok: false as const, error: 'invalid:url', status: 400 };
  return invoke<{ submission_id: string; status: string }>('core', 'social', {
    action: 'submit',
    claim_id: input.claimId,
    account_id: input.accountId,
    ...(postId ? { post_id: postId } : { url }),
  });
}

// ── Verifikasi YouTube tanpa OAuth (D-11): kode di deskripsi channel → akun terverifikasi (data publik) ──
export function youtubeCode(channel: string) {
  const ch = channel.trim().slice(0, 200);
  if (!ch) return Promise.resolve({ ok: false as const, error: 'bad_channel', status: 400 });
  return invoke<{ handle: string; code: string }>('core', 'social', { action: 'youtube_code', channel: ch });
}

export function youtubeVerify(channel: string) {
  const ch = channel.trim().slice(0, 200);
  if (!ch) return Promise.resolve({ ok: false as const, error: 'bad_channel', status: 400 });
  return invoke<{ handle: string }>('core', 'social', { action: 'youtube_verify', channel: ch });
}

// ── Tugas (F-C07) — query sama dengan app/tasks/page.tsx web ──
export async function tasks(uid: string) {
  const now = new Date().toISOString();
  const [claims, subs, accounts, terms] = await Promise.all([
    core.from('claims').select('id,campaign_id,expires_at').eq('user_id', uid).eq('status', 'open').gt('expires_at', now).order('expires_at'),
    core
      .from('submissions')
      .select('id,campaign_id,platform,url,status,counted_views,last_views,last_snapshot_at,created_at,social_account_id,posted_at,locked_at')
      .eq('user_id', uid)
      .order('created_at', { ascending: false })
      .limit(100),
    core.from('social_accounts').select('id,status').eq('user_id', uid),
    core.rpc('my_clip_terms'),
  ]);
  const list = must(subs) ?? [];
  const open = must(claims) ?? [];
  const ids = list.map((s) => s.id!).filter(Boolean);
  const campaignIds = [...new Set([...list.map((s) => s.campaign_id!), ...open.map((c) => c.campaign_id!)])].filter(Boolean);
  const [campaigns, earnings, decisions] = await Promise.all([
    campaignIds.length ? core.from('campaigns').select('id,title,view_window_days').in('id', campaignIds) : Promise.resolve({ data: [] as { id: string | null; title: string | null; view_window_days: number | null }[] }),
    ids.length ? core.from('clip_earnings').select('submission_id,pool_id,amount,released_at').in('submission_id', ids) : Promise.resolve({ data: [] as EarningRow[] }),
    ids.length
      ? core.from('review_decisions').select('target_id,decision,reason_code,message,created_at').eq('target_type', 'submission').in('target_id', ids).order('created_at', { ascending: false })
      : Promise.resolve({ data: [] as { target_id: string | null; decision: string | null; reason_code: string | null; message: string | null; created_at: string | null }[] }),
  ]);
  const camp = new Map((campaigns.data ?? []).map((c) => [c.id, c]));
  const poolIds = [...new Set((earnings.data ?? []).map((e) => e.pool_id))].filter((x): x is string => !!x);
  const pools = poolIds.length ? must(await core.from('reward_pools').select('id,reward_type_id').in('id', poolIds)) ?? [] : [];
  const units = await rewardTypes(pools.map((p) => p.reward_type_id));
  const earned = earningsBySubmission(earnings.data ?? [], new Map(pools.map((p) => [p.id, units.get(p.reward_type_id ?? '')])));
  const accountStatus = new Map((accounts.data ?? []).map((a) => [a.id, a.status]));
  const holdOf = (p: string | null) => {
    const v = terms.data && typeof terms.data === 'object' && !Array.isArray(terms.data) ? (terms.data as Record<string, { hold_days?: unknown }>)[p ?? ''] : undefined;
    return num(v?.hold_days ?? 7) || 7;
  };
  return {
    claims: open.map((c) => ({ id: c.id!, campaignId: c.campaign_id!, expiresAt: c.expires_at!, title: camp.get(c.campaign_id)?.title ?? '' })),
    submissions: list.map((s) => {
      const decs = (decisions.data ?? []).filter((d) => d.target_id === s.id);
      const verdict = decs.find((d) => d.decision !== 'appeal') ?? null;
      const status = s.status ?? '';
      return {
        id: s.id!,
        campaignId: s.campaign_id!,
        title: camp.get(s.campaign_id)?.title ?? '',
        platform: (isPlatform(s.platform) ? s.platform : null) as Platform | null,
        url: s.url ?? '',
        status,
        views: num(s.last_views ?? s.counted_views),
        counted: s.last_views != null && num(s.last_views) !== num(s.counted_views) ? num(s.counted_views) : null,
        updatedAt: s.last_snapshot_at ?? null,
        earned: earned(s.id!),
        paused: (status === 'tracking' || status === 'flagged') && accountStatus.get(s.social_account_id) !== 'verified',
        release:
          status === 'tracking' || status === 'locked' || status === 'flagged'
            ? estimateRelease({ locked_at: s.locked_at ?? null, posted_at: s.posted_at ?? null, created_at: s.created_at! }, num(camp.get(s.campaign_id)?.view_window_days) || 30, holdOf(s.platform)).toISOString()
            : null,
        verdict: verdict ? { code: verdict.reason_code, message: verdict.message } : null,
        appealUsed: decs.some((d) => d.decision === 'appeal'),
      };
    }),
  };
}

/** Banding submisi ditolak, sekali (validasi sama dengan server action appealSubmission web). */
export async function appealSubmission(id: string, message: string): Promise<{ ok: true } | { ok: false; code: string }> {
  const m = message.trim();
  if (!isUuid(id)) return { ok: false, code: 'bad_request' };
  if (!m || m.length > 1000) return { ok: false, code: 'invalid:message' };
  const { error } = await core.rpc('appeal_submission', { p_submission: id, p_message: m });
  return error ? { ok: false, code: error.message } : { ok: true };
}

// ── Wallet (F-C08): wallet_balances per state + riwayat (cermin release disembunyikan, sama dengan web) ──
export async function wallet(uid: string) {
  const [bal, idrRow, entries, set, payouts, fulfillments, live, terms] = await Promise.all([
    core.from('wallet_balances').select('reward_type_id,state,amount').eq('user_id', uid),
    core.from('reward_types').select('id').eq('code', 'IDR').is('owner_org_id', null).maybeSingle(),
    core.from('wallet_entries').select('id,reward_type_id,amount,state,ref_type,created_at').eq('user_id', uid).order('created_at', { ascending: false }).limit(60),
    settings(['public.finance.min_withdraw_idr']),
    core.from('payouts').select('id,amount,fee,channel,status,created_at,paid_at').eq('user_id', uid).order('created_at', { ascending: false }).limit(10),
    core.from('fulfillments').select('id,reward_type_id,amount,status,delivered_ref,created_at,delivered_at').eq('user_id', uid).order('created_at', { ascending: false }).limit(30),
    core.from('submissions').select('campaign_id,platform,posted_at,locked_at,created_at').eq('user_id', uid).in('status', ['tracking', 'flagged', 'locked']).limit(100),
    core.rpc('my_clip_terms'),
  ]);
  const rows = must(bal) ?? [];
  const idrId = idrRow.data?.id ?? null;
  const ful = must(fulfillments) ?? [];
  const liveRows = live.data ?? [];
  const [units, codes, windows] = await Promise.all([
    rewardTypes([...rows.map((r) => r.reward_type_id), ...(must(entries) ?? []).map((e) => e.reward_type_id), ...ful.map((f) => f.reward_type_id), idrId]),
    ful.length ? core.from('reward_codes').select('fulfillment_id,code').in('fulfillment_id', ful.map((f) => f.id!)) : Promise.resolve({ data: [] as { fulfillment_id: string | null; code: string | null }[] }),
    liveRows.length ? core.from('campaigns').select('id,view_window_days').in('id', [...new Set(liveRows.map((x) => x.campaign_id!))]) : Promise.resolve({ data: [] as { id: string | null; view_window_days: number | null }[] }),
  ]);
  const sum = (state: string, unit: string | null) => rows.filter((r) => r.state === state && r.reward_type_id === unit).reduce((a, r) => a + num(r.amount), 0);
  const others = [...units.values()]
    .filter((u) => u.id !== idrId)
    .map((u) => ({ unit: u, pending: sum('pending', u.id), available: sum('available', u.id), withdrawn: sum('withdrawn', u.id) }))
    .filter((b) => b.pending || b.available || b.withdrawn);
  const hold = (p: string | null) => {
    const v = terms.data && typeof terms.data === 'object' && !Array.isArray(terms.data) ? (terms.data as Record<string, { hold_days?: unknown }>)[p ?? ''] : undefined;
    return num(v?.hold_days ?? 7) || 7;
  };
  const windowOf = new Map((windows.data ?? []).map((c) => [c.id, num(c.view_window_days) || 30]));
  const nextRelease =
    liveRows
      .map((x) => estimateRelease({ locked_at: x.locked_at ?? null, posted_at: x.posted_at ?? null, created_at: x.created_at! }, windowOf.get(x.campaign_id) ?? 30, hold(x.platform)))
      .filter((d) => d.getTime() > Date.now())
      .sort((a, b) => a.getTime() - b.getTime())[0]
      ?.toISOString() ?? null;
  const codeOf = new Map((codes.data ?? []).map((x) => [x.fulfillment_id, x.code]));
  return {
    idr: { pending: sum('pending', idrId), available: sum('available', idrId), withdrawn: sum('withdrawn', idrId) },
    others,
    min: num(set['public.finance.min_withdraw_idr']) || 100_000,
    units,
    nextRelease,
    payouts: (must(payouts) ?? []).map((x) => ({ id: x.id!, net: num(x.amount) - num(x.fee), channel: x.channel ?? '', status: x.status ?? '', createdAt: x.created_at!, paidAt: x.paid_at ?? null })),
    fulfillments: ful.map((f) => ({ id: f.id!, unit: units.get(f.reward_type_id ?? '') ?? null, amount: num(f.amount), status: f.status ?? '', createdAt: f.created_at!, code: codeOf.get(f.id) ?? null })),
    // Riwayat: baris cermin (bucket Ditarik, sisi pending dari release) disembunyikan — sama dengan web.
    history: (must(entries) ?? []).filter((e) => e.state !== 'withdrawn' && !(e.ref_type === 'release' && num(e.amount) < 0)),
  };
}

// ── Akun (hub tab Akun, menu akun web §6.8) ──
export async function accountHub(uid: string) {
  const [info, me, set] = await Promise.all([
    chrome(uid),
    core.from('my_profile').select('trust_score').maybeSingle(),
    settings(['public.community.links', 'public.flags.ai_clip', 'public.ai_clip.url']),
  ]);
  return {
    ...info,
    trust: num(me.data?.trust_score),
    community: communityLinks(set['public.community.links']),
    aiClip: set['public.flags.ai_clip'] === true ? httpsUrl(set['public.ai_clip.url']) : null,
  };
}

// ── Profil & Trust Score (F-C12) — query sama dengan app/profile/page.tsx web ──
export async function profile(uid: string) {
  const [stats, me, events, sanctions, set] = await Promise.all([
    core.rpc('my_stats'),
    core.from('my_profile').select('username,display_name,avatar_path,trust_score,status,suspended_until,created_at').maybeSingle(),
    core.from('score_events').select('id,delta,reason,created_at').eq('user_id', uid).order('created_at', { ascending: false }).limit(30),
    core.from('sanctions').select('id,kind,reason,created_at,appealed_at,decision,decision_note').order('created_at', { ascending: false }).limit(20),
    settings(['public.finance.instant_min_trust', 'public.finance.trust_tiers', 'public.finance.hold_days', 'public.community.links']),
  ]);
  const st = (stats.data && typeof stats.data === 'object' ? stats.data : {}) as Record<string, unknown>;
  const score = num(me.data?.trust_score ?? st.trust_score);
  return {
    me: me.data,
    avatar: publicUrl('avatars', me.data?.avatar_path),
    score,
    stats: st,
    earnings: arr<Record<string, unknown>>(st.earnings),
    effects: trustEffects(score, { instantMin: set['public.finance.instant_min_trust'], holdDays: set['public.finance.hold_days'], tiers: set['public.finance.trust_tiers'] }),
    events: must(events) ?? [],
    sanctions: must(sanctions) ?? [],
    support: communityLinks(set['public.community.links']).find((l) => l.key === 'support')?.href ?? null,
  };
}

const AVATAR_TYPES: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };

/** Edit profil (server action saveProfile + avatarUploadUrl web): nama 1–50, foto ≤ 1 MB jpeg/png/webp di avatars/<uid>/. */
export async function saveProfile(uid: string, input: { displayName: string; photo?: { uri: string; mime: string } | null }): Promise<{ ok: true } | { ok: false; code: string }> {
  const name = input.displayName.trim();
  if (!name || name.length > 50) return { ok: false, code: 'invalid:display_name' };
  const mine = await core.from('my_profile').select('username,avatar_path').maybeSingle();
  if (!mine.data?.username) return { ok: false, code: 'not_eligible:profile_missing' };
  let avatarPath = mine.data.avatar_path ?? null;
  if (input.photo) {
    const ext = AVATAR_TYPES[input.photo.mime];
    if (!ext) return { ok: false, code: 'invalid:avatar_type' };
    const body = await (await fetch(input.photo.uri)).arrayBuffer();
    if (body.byteLength > 1_000_000) return { ok: false, code: 'invalid:avatar_size' };
    avatarPath = `${uid}/${randomId()}.${ext}`;
    const up = await core.storage.from('avatars').upload(avatarPath, body, { contentType: input.photo.mime, upsert: false });
    if (up.error) return { ok: false, code: up.error.message };
  }
  const { error } = await core.rpc('ensure_profile', { p_username: mine.data.username, p_display_name: name, ...(avatarPath ? { p_avatar_path: avatarPath } : {}) });
  return error ? { ok: false, code: error.message } : { ok: true };
}

export async function appealSanction(id: string, message: string): Promise<{ ok: true } | { ok: false; code: string }> {
  const m = message.trim();
  if (m.length < 10 || m.length > 1000) return { ok: false, code: 'invalid:message' };
  const { error } = await core.rpc('appeal_sanction', { p_sanction: id, p_message: m });
  return error ? { ok: false, code: error.message } : { ok: true };
}

/** Id acak untuk nama file / kunci idempotensi (crypto.randomUUID bila ada). */
export function randomId(): string {
  const g = globalThis.crypto as Crypto | undefined;
  if (g?.randomUUID) return g.randomUUID();
  const b = new Uint8Array(16);
  if (g?.getRandomValues) g.getRandomValues(b);
  else for (let i = 0; i < 16; i++) b[i] = Math.floor(Math.random() * 256);
  b[6] = (b[6]! & 0x0f) | 0x40;
  b[8] = (b[8]! & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// ── Leaderboard (F-C13) — api.leaderboard, refresh tiap jam ──
export type BoardRow = { user_id: string | null; username: string | null; avatar_path: string | null; views: number | null; rank: number | null };
const BOARD_COLS = 'user_id,username,avatar_path,views,rank';

export async function leaderboard(uid: string, campaign: string | null) {
  const week = weekStartUtc(new Date()).toISOString();
  const mySubs = await core.from('submissions').select('campaign_id,created_at').eq('user_id', uid).order('created_at', { ascending: false }).limit(100);
  const ids = [...new Set([...(isUuid(campaign) ? [campaign!] : []), ...(mySubs.data ?? []).map((x) => x.campaign_id!).filter(Boolean)])];
  const titles = ids.length ? ((await core.from('campaigns').select('id,title').in('id', ids)).data ?? []) : [];
  const options = ids.map((id) => ({ id, title: titles.find((c) => c.id === id)?.title ?? '' })).filter((o) => o.title);
  const selected = isUuid(campaign) && options.some((o) => o.id === campaign) ? campaign! : (options[0]?.id ?? null);
  const [weekRows, weekMine, campRows, campMine] = await Promise.all([
    core.from('leaderboard').select(BOARD_COLS).eq('scope', 'week').eq('week_start', week).order('rank').limit(50),
    core.from('leaderboard').select(BOARD_COLS).eq('scope', 'week').eq('week_start', week).eq('user_id', uid).maybeSingle(),
    selected ? core.from('leaderboard').select(BOARD_COLS).eq('scope', 'campaign').eq('campaign_id', selected).order('rank').limit(50) : Promise.resolve({ data: [] as BoardRow[] }),
    selected ? core.from('leaderboard').select(BOARD_COLS).eq('scope', 'campaign').eq('campaign_id', selected).eq('user_id', uid).maybeSingle() : Promise.resolve({ data: null }),
  ]);
  return { week, options, selected, weekRows: (weekRows.data ?? []) as BoardRow[], weekMine: weekMine.data as BoardRow | null, campRows: (campRows.data ?? []) as BoardRow[], campMine: campMine.data as BoardRow | null };
}

// ── Ajak teman (F-C16) ──
export async function referral(uid: string) {
  const [code, friends, bonus] = await Promise.all([
    core.rpc('my_referral_code'),
    core.from('referrals').select('referred_username,qualified_at,bonus_until,created_at').order('created_at', { ascending: false }).limit(100),
    core.from('wallet_entries').select('reward_type_id,amount').eq('user_id', uid).eq('ref_type', 'referral_bonus').gt('amount', 0),
  ]);
  if (code.error || !code.data) throw new Error(code.error?.message ?? 'generic');
  const totals = new Map<string, number>();
  for (const b of bonus.data ?? []) totals.set(b.reward_type_id ?? '', (totals.get(b.reward_type_id ?? '') ?? 0) + num(b.amount));
  const units = await rewardTypes(totals.keys());
  return { code: String(code.data), friends: friends.data ?? [], totals: [...totals].map(([id, v]) => ({ unit: units.get(id) ?? null, total: v })) };
}

// ── Tarik saldo (F-C09 / F-C15 / C6.1) — query sama dengan app/wallet/withdraw/page.tsx web ──
export async function withdrawContext(uid: string) {
  const [w, set, me, fee, methods, recipients] = await Promise.all([
    wallet(uid),
    settings(['public.finance.min_withdraw_idr', 'public.flags.instant_withdraw', 'public.finance.instant_min_trust', 'public.community.links']),
    core.from('my_profile').select('trust_score,status,suspended_until').maybeSingle(),
    core.from('fee_rules').select('instant_withdraw_fee').eq('scope', 'global').maybeSingle(),
    identityApi.rpc('my_payout_methods'),
    identityApi.from('my_recipients').select('id,reward_type_id'),
  ]);
  const trust = num(me.data?.trust_score);
  const minTrust = num(set['public.finance.instant_min_trust']) || 70;
  const flag = set['public.flags.instant_withdraw'] === true;
  const status = me.data?.status;
  return {
    available: w.idr.available,
    min: num(set['public.finance.min_withdraw_idr']) || 100_000,
    fee: num(fee.data?.instant_withdraw_fee),
    instant: { enabled: flag && trust >= minTrust, flag, trust, minTrust },
    inactive: status === 'banned' || status === 'closed' || (status === 'suspended' && (!me.data?.suspended_until || new Date(me.data.suspended_until) > new Date())),
    support: communityLinks(set['public.community.links']).find((l) => l.key === 'support')?.href ?? null,
    methods: (methods.data ?? []).map((m) => ({ id: m.id, bank: m.bank_code, last4: m.account_last4, name: m.account_name, kind: m.kind })),
    methodsError: methods.error?.message ?? null,
    rewards: w.others.filter((b) => b.unit.fulfillment !== 'payout' && b.available > 0),
    recipientOf: new Map((recipients.data ?? []).map((r) => [r.reward_type_id, r.id])),
  };
}

const IDEM = /^[A-Za-z0-9-]{8,100}$/;

/** Validasi sama dengan server action requestPayout web; idempotency per percobaan form. */
export async function requestPayout(input: { method: string; amount: number; channel: 'batch' | 'instant'; idempotency: string }): Promise<{ ok: true; status: string } | { ok: false; code: string }> {
  if (!isUuid(input.method)) return { ok: false, code: 'invalid:method' };
  if (!Number.isInteger(input.amount) || input.amount <= 0) return { ok: false, code: 'invalid:amount' };
  if (input.channel !== 'batch' && input.channel !== 'instant') return { ok: false, code: 'invalid:channel' };
  if (!IDEM.test(input.idempotency)) return { ok: false, code: 'invalid:idempotency' };
  const { data, error } = await core.rpc('request_payout', { p_method: input.method, p_amount: input.amount, p_channel: input.channel, p_idempotency: input.idempotency });
  return error ? { ok: false, code: error.message } : { ok: true, status: (data as { status?: string } | null)?.status ?? 'requested' };
}

export async function requestFulfillment(input: { rewardType: string; amount: number; recipient: Record<string, string>; recipientRef: string | null; idempotency: string }): Promise<{ ok: true } | { ok: false; code: string }> {
  if (!isUuid(input.rewardType)) return { ok: false, code: 'invalid:reward_type' };
  if (!Number.isFinite(input.amount) || input.amount <= 0) return { ok: false, code: 'invalid:amount' };
  if (input.recipientRef !== null && !isUuid(input.recipientRef)) return { ok: false, code: 'recipient_ref_required' };
  if (!IDEM.test(input.idempotency)) return { ok: false, code: 'invalid:idempotency' };
  const recipient = Object.fromEntries(
    Object.entries(input.recipient)
      .filter(([k, v]) => /^[a-z0-9_]{1,40}$/i.test(k) && typeof v === 'string')
      .map(([k, v]) => [k, v.trim().slice(0, 200)]),
  );
  const { error } = await core.rpc('request_fulfillment', { p_reward_type: input.rewardType, p_amount: input.amount, p_recipient: recipient, p_recipient_ref: input.recipientRef as string, p_idempotency: input.idempotency });
  return error ? { ok: false, code: error.message } : { ok: true };
}

// ── Pengaturan (C2.5) ──
export async function notificationSettings(uid: string) {
  const [prefs, devices] = await Promise.all([
    core.from('notification_prefs').select('email_promotions').eq('user_id', uid).maybeSingle(),
    identityApi.from('push_subscriptions').select('id', { count: 'exact', head: true }),
  ]);
  return { promotions: prefs.data?.email_promotions ?? true, devices: devices.count ?? 0 };
}

/** Sama dengan server action setEmailPromotions web: update, atau insert kalau baris belum ada. */
export async function setEmailPromotions(uid: string, on: boolean): Promise<boolean> {
  const { data, error } = await core.from('notification_prefs').update({ email_promotions: on, updated_at: new Date().toISOString() }).eq('user_id', uid).select('user_id');
  if (error) return false;
  if (data?.length) return true;
  return !(await core.from('notification_prefs').insert({ user_id: uid, email_promotions: on })).error;
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
  const camps = open.length ? must(await core.from('campaigns').select('id,title,platforms').in('id', open.map((c) => c.campaign_id!))) ?? [] : [];
  const byId = new Map(camps.map((c) => [c.id, c]));
  return open.map((c) => ({
    id: c.id!,
    campaignId: c.campaign_id!,
    expiresAt: c.expires_at!,
    title: byId.get(c.campaign_id)?.title ?? '',
    platforms: (byId.get(c.campaign_id)?.platforms ?? []).filter(isPlatform) as Platform[],
  }));
}

// ── Widget layar utama (src/widget-snapshot.ts): query ringan, aman dipanggil handler headless Android ──
export async function widgetData(uid: string, locale: 'id' | 'en'): Promise<WidgetInput> {
  const [bal, idrRow, payout, review, page] = await Promise.all([
    core.from('wallet_balances').select('reward_type_id,state,amount').eq('user_id', uid),
    core.from('reward_types').select('id').eq('code', 'IDR').is('owner_org_id', null).maybeSingle(),
    core.from('payouts').select('status,channel,method_id').eq('user_id', uid).in('status', ['requested', 'on_hold', 'processing']).order('created_at', { ascending: false }).limit(1).maybeSingle(),
    core.from('submissions').select('id', { count: 'exact', head: true }).eq('user_id', uid).in('status', ['validating', 'in_review', 'appealed']),
    campaignPage(uid, { q: '', platform: '', category: '', status: 'active', sort: 'newest' }, null, locale),
  ]);
  const idrId = idrRow.data?.id ?? null;
  const sum = (state: string) => (must(bal) ?? []).filter((r) => r.state === state && r.reward_type_id === idrId).reduce((a, r) => a + num(r.amount), 0);
  const p = payout.data;
  const method = p?.method_id ? (await identityApi.rpc('my_payout_methods')).data?.find((m) => m.id === p.method_id) : undefined;
  return {
    signedIn: true,
    available: sum('available'),
    pending: sum('pending'),
    payout: p ? { status: p.status ?? '', channel: p.channel ?? '', bank_code: method?.bank_code ?? null, account_last4: method?.account_last4 ?? null } : null,
    review: review.count ?? 0,
    campaigns: page.items,
  };
}
