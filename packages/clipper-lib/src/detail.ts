// api.campaign_detail (jsonb) → bentuk bertipe untuk halaman detail (F-C04–C06).
import type { RateRule } from './pure';
import { arr, num, str } from './pure';

export interface DetailCampaign {
  id: string;
  title: string;
  type: string;
  category_id: string | null;
  status: string;
  platforms: string[];
  brief: string;
  required_hashtags: string[];
  required_mentions: string[];
  required_links: string[];
  sponsored_label: boolean;
  min_duration_sec: number | null;
  max_duration_sec: number | null;
  dos: string[];
  donts: string[];
  example_urls: string[];
  faq: { q: string; a: string }[];
  start_at: string | null;
  submit_deadline: string | null;
  view_window_days: number;
  review_mode: string;
  min_followers: number;
  min_account_age_days: number;
  min_trust_score: number;
  kyc_required: boolean;
  min_views: number;
  max_clips_per_clipper: number;
  clipper_quota: number | null;
  visibility: string;
}

export interface DetailPool {
  pool_id: string;
  reward_type_id: string;
  code: string;
  unit_label: string;
  decimals: number;
  idr_value_per_unit: number;
  total: number;
  remaining: number;
  max_per_clip: number | null;
}

export interface DetailAsset {
  id: string;
  kind: string;
  url: string | null;
  storage_path: string | null;
  bucket: string | null;
  size_bytes: number | null;
}

export interface DetailSubmission {
  id: string;
  status: string;
  platform: string;
  url: string;
  counted_views: number;
  last_snapshot_at: string | null;
  created_at: string;
  review: { decision: string; reason_code: string | null; message: string | null } | null;
  appeal_used: boolean;
}

export interface CampaignDetail {
  campaign: DetailCampaign;
  brand: { name: string; verified: boolean } | null;
  rules: RateRule[];
  pools: DetailPool[];
  budget_idr: number;
  remaining_idr: number;
  est_remaining_views: Record<string, number>;
  clipper_fee_pct: number;
  assets: DetailAsset[];
  my: {
    claim: { id: string; status: string; expires_at: string; created_at: string } | null;
    submissions: DetailSubmission[];
    clips_used: number;
  };
  cta_state: string | null;
  cta_reason: string | null;
}

type O = Record<string, unknown>;
const nul = (v: unknown) => (v === null || v === undefined ? null : num(v));

export function parseDetail(raw: unknown): CampaignDetail {
  const d = (raw ?? {}) as O;
  const c = (d.campaign ?? {}) as O;
  const my = (d.my ?? {}) as O;
  const claim = my.claim as O | null | undefined;
  const brand = (d.brand ?? null) as O | null;
  return {
    brand: brand && str(brand.name) ? { name: str(brand.name), verified: brand.verified === true } : null,
    campaign: {
      id: str(c.id),
      title: str(c.title),
      type: str(c.type),
      category_id: (c.category_id as string | null) ?? null,
      status: str(c.status),
      platforms: arr<string>(c.platforms),
      brief: str(c.brief),
      required_hashtags: arr<string>(c.required_hashtags),
      required_mentions: arr<string>(c.required_mentions),
      required_links: arr<string>(c.required_links),
      sponsored_label: c.sponsored_label !== false,
      min_duration_sec: nul(c.min_duration_sec),
      max_duration_sec: nul(c.max_duration_sec),
      dos: arr<string>(c.dos),
      donts: arr<string>(c.donts),
      example_urls: arr<string>(c.example_urls),
      faq: arr<O>(c.faq).map((f) => ({ q: str(f.q), a: str(f.a) })).filter((f) => f.q || f.a),
      start_at: (c.start_at as string | null) ?? null,
      submit_deadline: (c.submit_deadline as string | null) ?? null,
      view_window_days: num(c.view_window_days) || 30,
      review_mode: str(c.review_mode),
      min_followers: num(c.min_followers),
      min_account_age_days: num(c.min_account_age_days),
      min_trust_score: num(c.min_trust_score),
      kyc_required: c.kyc_required === true,
      min_views: num(c.min_views),
      max_clips_per_clipper: num(c.max_clips_per_clipper),
      clipper_quota: nul(c.clipper_quota),
      visibility: str(c.visibility),
    },
    rules: arr<RateRule>(d.rules),
    pools: arr<O>(d.pools).map((p) => ({
      pool_id: str(p.pool_id),
      reward_type_id: str(p.reward_type_id),
      code: str(p.code),
      unit_label: str(p.unit_label),
      decimals: num(p.decimals),
      idr_value_per_unit: num(p.idr_value_per_unit),
      total: num(p.total),
      remaining: num(p.remaining),
      max_per_clip: nul(p.max_per_clip),
    })),
    budget_idr: num(d.budget_idr),
    remaining_idr: num(d.remaining_idr),
    est_remaining_views: Object.fromEntries(
      Object.entries((d.est_remaining_views ?? {}) as O).map(([k, v]) => [k, num(v)]),
    ),
    clipper_fee_pct: num(d.clipper_fee_pct),
    assets: arr<O>(d.assets).map((a) => ({
      id: str(a.id),
      kind: str(a.kind),
      url: (a.url as string | null) ?? null,
      storage_path: (a.storage_path as string | null) ?? null,
      bucket: (a.bucket as string | null) ?? null,
      size_bytes: nul(a.size_bytes),
    })),
    my: {
      claim: claim
        ? { id: str(claim.id), status: str(claim.status), expires_at: str(claim.expires_at), created_at: str(claim.created_at) }
        : null,
      submissions: arr<O>(my.submissions).map((s) => ({
        id: str(s.id),
        status: str(s.status),
        platform: str(s.platform),
        url: str(s.url),
        counted_views: num(s.counted_views),
        last_snapshot_at: (s.last_snapshot_at as string | null) ?? null,
        created_at: str(s.created_at),
        review: s.review
          ? {
              decision: str((s.review as O).decision),
              reason_code: ((s.review as O).reason_code as string | null) ?? null,
              message: ((s.review as O).message as string | null) ?? null,
            }
          : null,
        appeal_used: s.appeal_used === true,
      })),
      clips_used: num(my.clips_used),
    },
    cta_state: (d.cta_state as string | null) ?? null,
    cta_reason: (d.cta_reason as string | null) ?? null,
  };
}
