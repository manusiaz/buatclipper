import type { Platform } from '@clipper/ui';
import { num } from '../../lib/settings';

const PLATFORMS: readonly Platform[] = ['tiktok', 'instagram', 'youtube', 'threads', 'facebook', 'x'];
const isPlatform = (v: unknown): v is Platform => typeof v === 'string' && (PLATFORMS as readonly string[]).includes(v);
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const str = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null);

export interface Report {
  campaign: { title: string; status: string; startAt: string | null; submitDeadline: string | null; platforms: Platform[] };
  viewsValid: number;
  clips: number;
  clippers: number;
  byPlatform: Array<{ platform: Platform; views: number }>;
  budget: Array<{ code: string; unit: string; total: number; spent: number }>;
  topClips: Array<{ url: string; platform: Platform | null; views: number }>;
}

/** Hasil api.report_by_token (market.campaign_report) → bentuk bertipe; null = link tidak berlaku. */
export function parseReport(json: unknown): Report | null {
  const r = obj(json);
  const c = obj(r.campaign);
  const title = str(c.title);
  if (!title) return null;
  return {
    campaign: {
      title,
      status: str(c.status) ?? '',
      startAt: str(c.start_at),
      submitDeadline: str(c.submit_deadline),
      platforms: (Array.isArray(c.platforms) ? c.platforms : []).filter(isPlatform),
    },
    viewsValid: num(r.views_valid) ?? 0,
    clips: num(r.clips) ?? 0,
    clippers: num(r.clippers) ?? 0,
    byPlatform: Object.entries(obj(r.by_platform))
      .filter(([p]) => isPlatform(p))
      .map(([platform, v]) => ({ platform: platform as Platform, views: num(v) ?? 0 }))
      .sort((a, b) => b.views - a.views),
    budget: (Array.isArray(r.budget) ? r.budget : []).map(obj).map((b) => ({
      code: str(b.reward_type) ?? '',
      unit: str(b.unit) ?? '',
      total: num(b.total) ?? 0,
      spent: num(b.spent) ?? 0,
    })),
    topClips: (Array.isArray(r.top_clips) ? r.top_clips : [])
      .map(obj)
      .map((t) => ({ url: str(t.url) ?? '', platform: isPlatform(t.platform) ? t.platform : null, views: num(t.views) ?? 0 }))
      .filter((t) => /^https:\/\//.test(t.url)),
  };
}

/** Token api.create_report_link = base64url (32 byte → 43 karakter). Bentuk lain tidak perlu ditanyakan ke DB. */
export const isReportToken = (t: string) => /^[A-Za-z0-9_-]{20,128}$/.test(t);
