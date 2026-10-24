// Notifikasi in-app (E-23, F-C11): event + payload → kunci pesan namespace notifications + nilai + deep link.
// Event & kunci payload = db/identity/supabase/functions/_shared/templates.ts (41 event, sama dengan email/push).
import { REJECT_REASONS } from '@clipper/i18n/core';
import { formatDate, formatDateTime, formatIDR, formatNumber, formatRelative, type UiLocale } from '@clipper/ui/format';
import type { IconName } from '@clipper/ui/icons';
import { platformLabel, type Platform } from '@clipper/ui/platform-paths';
import { isPlatform, num } from './pure';
import { formatAmount } from './units';

export const EVENTS = [
  'campaign.new', 'campaign.invited', 'claim.expiring', 'submission.approved', 'submission.rejected', 'submission.forfeited',
  'submission.pending_review', 'social.token_expired', 'earning.available', 'earning.held', 'payout.processing', 'payout.paid', 'payout.failed',
  'fulfillment.delivered', 'fulfillment.cancelled', 'payout.cancelled', 'kyc.approved', 'kyc.rejected', 'broadcast.sent',
  'account.suspended', 'account.banned', 'invoice.issued', 'invoice.paid', 'campaign.approved', 'campaign.rejected',
  'campaign.live', 'budget.used', 'budget.projection_low', 'campaign.settled', 'org.verified', 'org.rejected',
  'org.suspended', 'agency.link_requested', 'agency.link_approved', 'refund.requested', 'refund.paid', 'managed.draft_ready',
  'account.warned', 'sanction.appeal_decided', 'security.notice',
] as const;

export type NotificationEvent = (typeof EVENTS)[number];
export const isEvent = (e: unknown): e is NotificationEvent => typeof e === 'string' && (EVENTS as readonly string[]).includes(e);

export interface Links {
  brand: string;
  accounts: string;
}

type P = Record<string, unknown>;

/** Ikon per keluarga event (prefix sebelum titik) — kotak notifikasi web & native. */
const ICON: Record<string, IconName> = {
  campaign: 'campaign',
  claim: 'timer',
  submission: 'checklist',
  social: 'link',
  earning: 'payments',
  payout: 'account_balance_wallet',
  fulfillment: 'redeem',
  kyc: 'id_card',
  broadcast: 'notifications',
  account: 'shield',
  invoice: 'receipt_long',
  budget: 'monitoring',
  org: 'storefront',
  agency: 'groups',
  refund: 'undo',
  managed: 'edit',
};
export const notificationIcon = (event: string): IconName => ICON[event.split('.')[0] ?? ''] ?? 'notifications';

const seg = (v: unknown): string | null => (typeof v === 'string' && /^[A-Za-z0-9_-]{1,80}$/.test(v) ? v : null);

export function text(p: P, key: string, max = 120): string {
  const v = p[key];
  if (typeof v !== 'string' && typeof v !== 'number') return '';
  const s = String(v).replace(/\s+/g, ' ').trim();
  return s.length > max ? `${s.slice(0, max - 1)}…` : s;
}

/** Deep link per event: halaman clipper relatif, brand/accounts absolut. null = tanpa tujuan. */
export function notificationHref(event: string, payload: P, links: Links): string | null {
  const campaign = seg(payload.campaign_id);
  const org = seg(payload.org_id);
  const brand = (...parts: string[]) => (org ? [links.brand, org, ...parts].join('/') : `${links.brand}/`);
  switch (event) {
    case 'campaign.new':
    case 'campaign.invited':
    case 'claim.expiring':
      return campaign ? `/campaigns/${campaign}` : '/campaigns';
    case 'submission.approved':
    case 'submission.rejected':
    case 'submission.forfeited':
      return '/tasks';
    case 'social.token_expired':
      return '/social';
    case 'earning.held':
      return payload.submission_id ? '/tasks' : '/wallet';
    case 'earning.available':
    case 'payout.processing':
    case 'payout.paid':
    case 'payout.failed':
    case 'payout.cancelled':
      return '/wallet';
    case 'fulfillment.delivered':
    case 'fulfillment.cancelled':
      return '/wallet?tab=reward';
    case 'kyc.approved':
    case 'kyc.rejected':
      return `${links.accounts}/kyc`;
    case 'account.banned':
      return `${links.accounts}/`;
    case 'security.notice':
      return `${links.accounts}/privacy`;
    case 'account.warned':
    case 'sanction.appeal_decided':
      return '/profile';
    case 'account.suspended':
    case 'broadcast.sent':
      return null;
    case 'submission.pending_review':
      return brand('review');
    case 'invoice.issued':
    case 'invoice.paid':
    case 'refund.requested':
    case 'refund.paid':
      return brand('billing');
    case 'campaign.approved':
    case 'campaign.rejected':
    case 'campaign.live':
    case 'campaign.settled':
    case 'budget.used':
    case 'budget.projection_low':
      return campaign ? brand('campaigns', campaign) : brand('campaigns');
    case 'org.verified':
      return brand('campaigns', 'new');
    case 'org.rejected':
    case 'org.suspended':
    case 'agency.link_requested':
      return brand('settings');
    case 'agency.link_approved':
      return `${links.brand}/`;
    case 'managed.draft_ready':
      return campaign && org ? `${brand('campaigns', 'new')}?campaign=${campaign}` : brand('campaigns', 'new');
    default:
      return null;
  }
}

/** budget.used pct → varian pesan (50 / 80 / habis). */
export function budgetLevel(pct: unknown): 'p50' | 'p80' | 'full' {
  const n = Number(pct);
  return n >= 100 ? 'full' : n >= 80 ? 'p80' : 'p50';
}

export interface AmountRef {
  amount: unknown;
  reward_type?: unknown;
  unit_label?: unknown;
}

/** Nominal payload (finance.amount_ref) atau daftar amounts (earning.available). */
export function amountRefs(payload: P): AmountRef[] {
  if (Array.isArray(payload.amounts)) return payload.amounts.filter((a): a is AmountRef => !!a && typeof a === 'object');
  return payload.amount !== undefined && payload.amount !== null ? [payload as unknown as AmountRef] : [];
}

const count = (v: unknown) => {
  const n = typeof v === 'number' ? v : typeof v === 'string' && /^\d{1,15}$/.test(v.trim()) ? Number(v) : NaN;
  return Number.isSafeInteger(n) && n > 0 ? n : null;
};
const isoDate = (v: unknown) => (typeof v === 'string' && !Number.isNaN(new Date(v).getTime()) ? v : null);

/** Rekening tujuan tersamar dari bridge identity ("BCA •• 4821"); tanpa bank_code → ''. */
export function bankLabel(p: P): string {
  const code = typeof p.bank_code === 'string' && /^[A-Za-z0-9_]{2,20}$/.test(p.bank_code) ? p.bank_code.replace(/_/g, ' ').toUpperCase() : '';
  const last4 = typeof p.account_last4 === 'string' && /^\d{4}$/.test(p.account_last4) ? p.account_last4 : '';
  return code && last4 ? `${code} •• ${last4}` : code;
}

/**
 * Angka konkret per event (DS: notifikasi bawa angka, bukan "ada update") — sama dengan baris push/email
 * templates.ts: "48.210 views dihitung · ±Rp96.400 sejauh ini · cair ±27 Okt". Field kosong dilewati; null = tanpa baris.
 */
export function notificationFacts(event: string, p: P, locale: UiLocale, t: (key: string, values?: Record<string, string>) => string, now = Date.now()): string | null {
  const money = (list: AmountRef[]) =>
    list.map((a) => formatAmount(num(a.amount), { code: String(a.reward_type ?? 'IDR'), unit_label: String(a.unit_label ?? ''), decimals: 2 }, locale)).join(' + ');
  const views = count(p.views);
  const out: string[] = [];
  const add = (key: string, values: Record<string, string>) => out.push(t(`facts.${key}`, values));
  const rate = Number(p.rate_per_1k) > 0 ? formatIDR(Number(p.rate_per_1k), { locale }) : null;
  switch (event) {
    case 'submission.approved': {
      if (views) add('views', { n: formatNumber(views, locale) });
      const est = Array.isArray(p.est_amounts) ? p.est_amounts.filter((a): a is AmountRef => !!a && typeof a === 'object' && num((a as AmountRef).amount) > 0) : [];
      if (est.length) add('estimate', { amount: money(est) });
      const release = isoDate(p.release_at);
      if (release) add('release', { date: formatDate(release, locale) });
      if (rate) add('rate', { rate });
      break;
    }
    case 'submission.rejected':
    case 'earning.available':
      if (views) add('views', { n: formatNumber(views, locale) });
      break;
    case 'submission.forfeited': {
      if (views) add('views', { n: formatNumber(views, locale) });
      const lost = amountRefs(p).filter((a) => num(a.amount) > 0);
      if (lost.length) add('lost', { amount: money(lost) });
      break;
    }
    case 'earning.held': {
      const held = amountRefs(p).filter((a) => num(a.amount) > 0);
      if (held.length) add('held', { amount: money(held) });
      break;
    }
    case 'claim.expiring': {
      const h = count(p.hours_left);
      if (h) add('hoursLeft', { n: formatNumber(h, locale) });
      break;
    }
    case 'campaign.new':
    case 'campaign.invited':
      if (rate) add('rate', { rate });
      break;
    case 'social.token_expired': {
      const n = count(p.paused_count);
      if (n) add('paused', { n: formatNumber(n, locale) });
      break;
    }
    case 'payout.processing':
    case 'payout.paid':
    case 'payout.failed':
    case 'payout.cancelled': {
      const bank = bankLabel(p);
      if (bank) add('to', { bank });
      if (Number(p.fee) > 0) add('fee', { amount: formatIDR(Number(p.fee), { locale }) });
      const eta = event === 'payout.processing' ? isoDate(p.eta_at) : null;
      if (eta && new Date(eta).getTime() > now) add('eta', { when: formatRelative(eta, now, locale) });
      break;
    }
  }
  return out.length ? out.join(' · ') : null;
}

export interface NotificationRow {
  id: number | null;
  event: string | null;
  payload: unknown;
  read_at: string | null;
  created_at: string | null;
}

export interface NotificationView {
  id: number;
  title: string;
  body: string;
  reason: string | null;
  /** Baris angka (views, estimasi, tanggal cair, ETA, biaya) — notificationFacts. */
  facts: string | null;
  href: string | null;
  read: boolean;
  createdAt: string;
  event: string;
}

/** Builder murni (web RSC & app native): t = namespace notifications, tc = namespace common. */
export function buildNotificationViews(
  rows: NotificationRow[],
  locale: UiLocale,
  t: (key: string, values?: Record<string, string>) => string,
  tc: (key: string) => string,
  links: Links,
): NotificationView[] {
  const when = (v: unknown) =>
    typeof v === 'string' && !Number.isNaN(new Date(v).getTime())
      ? `${formatDateTime(v, locale, { dateStyle: 'medium', timeStyle: 'short' })} WIB`
      : '';
  return rows
    .filter((r) => r.id !== null)
    .map((r) => {
      const p = (r.payload && typeof r.payload === 'object' ? r.payload : {}) as Record<string, unknown>;
      const event = r.event ?? '';
      const amounts = amountRefs(p)
        .map((a) => formatAmount(num(a.amount), { code: String(a.reward_type ?? 'IDR'), unit_label: String(a.unit_label ?? ''), decimals: 2 }, locale))
        .join(', ');
      const platform = text(p, 'platform', 30).toLowerCase();
      const values = {
        campaign: text(p, 'campaign_title') || t('fallback.campaign'),
        platform: isPlatform(platform) ? platformLabel(platform as Platform) : text(p, 'platform', 30) || t('fallback.platform'),
        handle: text(p, 'handle', 60) ? ` @${text(p, 'handle', 60)}` : '',
        amount: amounts || t('fallback.amount'),
        expiresAt: when(p.expires_at) || t('fallback.soon'),
        until: when(p.until) || t('fallback.further'),
        count: text(p, 'count', 6) || t('fallback.count'),
        invoice: text(p, 'invoice_number', 40) || t('fallback.invoice'),
        dueAt: when(p.due_at) || t('fallback.dueAt'),
        reward: text(p, 'reward_name') || t('fallback.reward'),
        title: text(p, 'title') || t('fallback.broadcast'),
        body: text(p, 'body', 600),
        org: text(p, 'org_name') || t('fallback.org'),
        agency: text(p, 'agency_org_name') || t('fallback.agency'),
        client: text(p, 'client_org_name') || t('fallback.client'),
        level: budgetLevel(p.pct),
        decision: text(p, 'decision', 20),
        cause: text(p, 'reason', 60).startsWith('fraud:') ? 'fraud' : 'gone',
        scope: p.submission_id ? 'submission' : 'account',
      };
      const known = isEvent(event);
      // Kode alasan standar → label common.rejectReasons; pesan reviewer ikut di belakangnya.
      const code = text(p, 'reason', 60);
      const label = (REJECT_REASONS as readonly string[]).includes(code) ? tc(`rejectReasons.${code}`) : null;
      const message = text(p, 'message', 300);
      const reason = label ? (message ? `${label} — ${message}` : label) : message || text(p, 'reason', 300);
      return {
        id: r.id!,
        event,
        title: known ? t(`${event}.title`, values) : t('unknown.title'),
        body: known ? t(`${event}.body`, values) : t('unknown.body'),
        reason: reason && event !== 'broadcast.sent' ? t('reason', { reason }) : null,
        facts: known ? notificationFacts(event, p, locale, t) : null,
        href: notificationHref(event, p, links),
        read: !!r.read_at,
        createdAt: r.created_at ?? new Date().toISOString(),
      };
    });
}
