// Isi widget layar utama (DS Android 05 "Widget 4×2 + 2×2", DS iOS 05 "Widget small + medium"): satu snapshot teks
// jadi untuk widget Android (react-native-android-widget, headless JS) dan iOS (expo-widgets, SwiftUI — fungsi widget
// tak bisa memanggil formatter app, jadi semua angka sudah berupa string). Murni; data mentah dimuat src/widget-data.ts.
import { createTranslator } from 'use-intl';
import { bankLabel } from '@clipper/clipper-lib/notifications';
import { nextBatchDate } from '@clipper/clipper-lib/pure';
import { formatIDR } from '@clipper/ui/format';
import id from '@clipper/i18n/messages/id/clipper';
import en from '@clipper/i18n/messages/en/clipper';

export type WidgetInput = {
  signedIn: boolean;
  available: number;
  pending: number;
  /** Penarikan IDR terbaru yang belum selesai (requested / on_hold / processing). */
  payout: { status: string; channel: string; bank_code?: string | null; account_last4?: string | null } | null;
  /** Clip menunggu keputusan (validating / in_review / appealed). */
  review: number;
  campaigns: { id: string; title: string; category?: string; isNew: boolean; ctaState?: string; rates: { ratePer1k: number }[]; budgetUsedRatio?: number }[];
};

export type WidgetCampaign = { title: string; sub: string; rate: string; url: string };

export type WidgetSnapshot = {
  signedIn: boolean;
  title: string;
  titleShort: string;
  balance: string;
  balanceShort: string;
  /** "Cair hari ini · BCA •• 4821", "Cair Senin", "Lagi ditransfer · …", "Siap ditarik", atau ''. */
  release: string;
  held: string;
  newLabel: string;
  newCount: string;
  rateLabel: string;
  topRate: string;
  reviewLabel: string;
  reviewCount: string;
  reviewLine: string;
  forYou: string;
  empty: string;
  signIn: string;
  campaigns: WidgetCampaign[];
};

const WIB = 7 * 3_600_000;

/** Batch mingguan Senin 10.00 WIB: hari ini kalau Senin sebelum jam 10, selain itu Senin berikutnya. */
export function batchIsToday(now: Date): boolean {
  const wib = new Date(now.getTime() + WIB);
  return wib.getUTCDay() === 1 && wib.getUTCHours() < 10;
}

export function buildWidgetSnapshot(input: WidgetInput, locale: 'id' | 'en', now = new Date()): WidgetSnapshot {
  const t = createTranslator({ locale, messages: { m: locale === 'en' ? en : id }, namespace: 'm', onError: () => {} });
  const w = (k: string, v?: Record<string, string>) => t(`mobile.widget.${k}` as never, v as never) as string;
  const idr = (v: number) => formatIDR(v, { locale });
  const fresh = input.campaigns.filter((c) => c.isNew);
  const rateOf = (c: WidgetInput['campaigns'][number]) => Math.max(0, ...c.rates.map((r) => r.ratePer1k));
  const top = Math.max(0, ...fresh.map(rateOf));
  const forYou = fresh.filter((c) => c.ctaState === 'can_claim' || c.ctaState === 'claimed_not_submitted' || !c.ctaState).slice(0, 3);
  const p = input.payout;
  const bank = p ? bankLabel(p as Record<string, unknown>) : '';
  const day = new Intl.DateTimeFormat(locale === 'en' ? 'en-US' : 'id-ID', { weekday: 'long', timeZone: 'Asia/Jakarta' }).format(nextBatchDate(now));
  const release = !p
    ? input.available > 0
      ? w('ready')
      : ''
    : [
        p.status === 'processing' || p.channel === 'instant'
          ? w('transferring')
          : p.status === 'on_hold'
            ? (t('wallet.payoutStatus.on_hold' as never) as string)
            : batchIsToday(now)
              ? w('releaseToday')
              : w('releaseOn', { day }),
        bank,
      ]
        .filter(Boolean)
        .join(' · ');
  return {
    signedIn: input.signedIn,
    title: w('title'),
    titleShort: w('titleShort'),
    balance: input.signedIn ? idr(input.available) : '—',
    balanceShort: input.signedIn ? formatIDR(input.available, { locale, compact: input.available >= 1_000_000 }) : '—',
    release: input.signedIn ? release : '',
    held: input.signedIn && input.pending > 0 ? w('held', { amount: idr(input.pending) }) : '',
    newLabel: w('newCampaigns'),
    newCount: String(fresh.length),
    rateLabel: w('topRate'),
    topRate: top > 0 ? idr(top) : '—',
    reviewLabel: w('review'),
    reviewCount: String(input.review),
    reviewLine: w('reviewLine', { n: String(input.review) }),
    forYou: w('forYou'),
    empty: w('noCampaigns'),
    signIn: w('signIn'),
    campaigns: forYou.map((c) => ({
      title: c.title,
      sub: [c.category, c.budgetUsedRatio != null ? w('left', { pct: String(Math.max(0, Math.round((1 - c.budgetUsedRatio) * 100))) }) : null].filter(Boolean).join(' · '),
      rate: rateOf(c) > 0 ? w('perK', { rate: idr(rateOf(c)) }) : '',
      url: `clipper://campaign/${c.id}`,
    })),
  };
}
