// Event notifikasi sisi brand (market.notify_org & alur finance). Payload notify_org selalu membawa org_id + org_name.
export const BRAND_EVENTS = [
  'invoice.issued',
  'invoice.paid',
  'campaign.approved',
  'campaign.rejected',
  'campaign.live',
  'campaign.settled',
  'budget.used',
  'budget.projection_low',
  'submission.pending_review',
  'org.verified',
  'org.rejected',
  'org.suspended',
  'agency.link_requested',
  'agency.link_approved',
  'refund.requested',
  'refund.paid',
  'managed.draft_ready',
] as const;

export type BrandEvent = (typeof BRAND_EVENTS)[number];

type Payload = Record<string, unknown>;

const s = (v: unknown): string => (typeof v === 'string' ? v : typeof v === 'number' ? String(v) : '');
const id = (v: unknown): string | null => (typeof v === 'string' && /^[0-9a-f-]{36}$/i.test(v) ? v : null);

export const isBrandEvent = (e: string | null | undefined): e is BrandEvent => (BRAND_EVENTS as readonly string[]).includes(e ?? '');

/** Halaman tujuan di brand.{domain}; null kalau payload tidak lengkap. */
export function notificationHref(event: BrandEvent, payload: Payload): string | null {
  const org = id(payload.org_id);
  const campaign = id(payload.campaign_id);
  if (event === 'agency.link_approved') return id(payload.client_org_id) ? `/${payload.client_org_id}/campaigns` : null;
  if (!org) return null;
  switch (event) {
    case 'invoice.issued':
    case 'invoice.paid':
      return id(payload.invoice_id) ? `/${org}/billing?invoice=${payload.invoice_id}` : `/${org}/billing`;
    case 'refund.requested':
    case 'refund.paid':
    case 'campaign.settled':
      return `/${org}/billing`;
    case 'managed.draft_ready':
      return campaign ? `/${org}/campaigns/new?campaign=${campaign}` : `/${org}/campaigns`;
    case 'campaign.rejected':
      return campaign ? `/${org}/campaigns/new?campaign=${campaign}` : `/${org}/campaigns`;
    case 'campaign.approved':
    case 'campaign.live':
    case 'budget.used':
    case 'budget.projection_low':
      return campaign ? `/${org}/campaigns/${campaign}` : `/${org}/campaigns`;
    case 'submission.pending_review':
      return `/${org}/review`;
    case 'org.verified':
    case 'org.rejected':
    case 'org.suspended':
    case 'agency.link_requested':
      return `/${org}/settings`;
  }
}

/** Nilai ICU untuk teks brand.notif.<event>; semua kunci selalu ada supaya format tidak gagal. */
export function notificationValues(payload: Payload, formatIdr: (n: number) => string): Record<string, string> {
  const amount = typeof payload.amount === 'number' ? payload.amount : typeof payload.total === 'number' ? payload.total : null;
  const unit = s(payload.reward_type);
  return {
    org: s(payload.org_name),
    campaign: s(payload.campaign_title),
    number: s(payload.invoice_number) || s(payload.number),
    amount: amount == null ? '' : !unit || unit === 'IDR' ? formatIdr(amount) : `${amount} ${s(payload.unit_label)}`,
    pct: s(payload.pct),
    projected: s(payload.projected_utilization_pct),
    agency: s(payload.agency_org_name),
    client: s(payload.client_org_name),
    reason: s(payload.reason),
  };
}
