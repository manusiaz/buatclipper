import { getLocale, getTranslations } from 'next-intl/server';
import { Card, CardContent, CardDescription, CardHeader, CardTitle, EmptyState, formatDate, formatIDR } from '@clipper/ui';
import type { OrgCredit } from './credit';

const REF_TYPES = ['rollover', 'refund', 'invoice_payment'];

export async function CreditCard({ credit }: { credit: OrgCredit }) {
  const [t, locale] = await Promise.all([getTranslations('brand.credit'), getLocale()]);
  const loc = locale === 'en' ? 'en' : 'id';
  const idr = (v: number, signed = false) => formatIDR(v, { locale: loc, signed, fractionDigits: Number.isInteger(v) ? 0 : 2 });
  const held = Math.max(0, credit.balance - credit.available);
  return (
    <Card>
      <CardHeader>
        <CardTitle>{t('title')}</CardTitle>
        <CardDescription>{t('description')}</CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        <dl className="grid grid-cols-1 gap-3 sm:grid-cols-3 [&>*]:min-w-0">
          <div className="rounded-card-sm bg-subtle p-3">
            <dt className="text-caption text-muted">{t('available')}</dt>
            <dd className="text-h5 text-ink tnum">{idr(credit.available)}</dd>
          </div>
          <div className="p-3">
            <dt className="text-caption text-muted">{t('balance')}</dt>
            <dd className="text-body font-semibold text-ink tnum">{idr(credit.balance)}</dd>
          </div>
          <div className="p-3">
            <dt className="text-caption text-muted">{t('held')}</dt>
            <dd className="text-body font-semibold text-ink tnum">{idr(held)}</dd>
          </div>
        </dl>
        {credit.history.length ? (
          <ul className="divide-y divide-border" aria-label={t('history')}>
            {credit.history.slice(0, 10).map((h, i) => (
              <li key={`${h.refId}-${i}`} className="flex flex-wrap items-center gap-x-3 gap-y-0.5 py-2.5 text-body-s">
                <span className="min-w-0 flex-1 text-text-2">{t(`ref.${REF_TYPES.includes(h.refType) ? h.refType : 'other'}`)}</span>
                <span className="text-caption text-muted">{h.createdAt ? formatDate(h.createdAt, loc) : ''}</span>
                <span className={h.amount < 0 ? 'w-32 text-right font-semibold text-ink tnum' : 'w-32 text-right font-semibold text-success-fg tnum'}>
                  {idr(h.amount, true)}
                </span>
              </li>
            ))}
          </ul>
        ) : (
          <EmptyState compact icon="account_balance_wallet" title={t('empty')} body={t('emptyBody')} />
        )}
      </CardContent>
    </Card>
  );
}
