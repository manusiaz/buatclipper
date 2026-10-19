// Baris api.notifications → judul/isi terjemahan (namespace notifications) + link.
import { getTranslations } from 'next-intl/server';
import { hosts } from '@clipper/auth';
import { formatDateTime, platformLabel, type Platform, type UiLocale } from '@clipper/ui';
import { isPlatform, num } from '../lib/pure';
import { formatAmount } from '../lib/units';
import { amountRefs, budgetLevel, isEvent, notificationHref, text } from './render';

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
  href: string | null;
  read: boolean;
  createdAt: string;
  event: string;
}

export async function notificationViews(rows: NotificationRow[], locale: UiLocale): Promise<NotificationView[]> {
  const t = await getTranslations('notifications');
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
      };
      const known = isEvent(event);
      const reason = text(p, 'message', 300) || text(p, 'reason', 300);
      return {
        id: r.id!,
        event,
        title: known ? t(`${event}.title`, values) : t('unknown.title'),
        body: known ? t(`${event}.body`, values) : t('unknown.body'),
        reason: reason && event !== 'broadcast.sent' ? t('reason', { reason }) : null,
        href: notificationHref(event, p, { brand: hosts.brand, accounts: hosts.accounts }),
        read: !!r.read_at,
        createdAt: r.created_at ?? new Date().toISOString(),
      };
    });
}
