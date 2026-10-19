import Link from 'next/link';
import { getLocale, getTranslations } from 'next-intl/server';
import {
  Alert,
  Badge,
  Button,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  CopyField,
  formatDate,
  formatDateTime,
  formatIDR,
} from '@clipper/ui';
import { QrCode } from './qr-code';
import { toDynamicQris } from './qris';

export interface InvoiceRow {
  id: string;
  number: string;
  kind: string;
  campaign_id: string | null;
  subtotal: number;
  mgmt_fee: number;
  admin_fee: number;
  service_fee: number;
  tax: number;
  total: number;
  status: string;
  payment_channel: string | null;
  paid_amount: number | null;
  paid_at: string | null;
  faktur_no: string | null;
  issued_at: string | null;
  due_at: string | null;
  pin_until: string | null;
}

export interface PaymentConfig {
  qrisMax: number;
  qrisPayload: string;
  bank: { bank: string; number: string; name: string };
}

export function invoiceTone(i: Pick<InvoiceRow, 'status' | 'due_at'>): { tone: 'success' | 'warn' | 'danger' | 'neutral'; key: string } {
  if (i.status === 'paid') return { tone: 'success', key: 'paid' };
  if (i.status === 'void') return { tone: 'neutral', key: 'void' };
  return i.due_at && new Date(i.due_at).getTime() < Date.now() ? { tone: 'danger', key: 'overdue' } : { tone: 'warn', key: 'issued' };
}

export async function InvoiceDetail({ invoice: inv, campaignTitle, orgId, pay }: { invoice: InvoiceRow; campaignTitle: string | null; orgId: string; pay: PaymentConfig }) {
  const [t, locale] = await Promise.all([getTranslations('brand.billing'), getLocale()]);
  const loc = locale === 'en' ? 'en' : 'id';
  const idr = (v: number) => formatIDR(v, { locale: loc, fractionDigits: Number.isInteger(v) ? 0 : 2 });
  const st = invoiceTone(inv);
  const useQris = inv.total <= pay.qrisMax;
  const qris = useQris && pay.qrisPayload ? toDynamicQris(pay.qrisPayload, inv.total) : null;
  const bankReady = !!(pay.bank.bank && pay.bank.number && pay.bank.name);
  const lines: [string, number][] = [
    [t('subtotal'), inv.subtotal],
    [t('mgmtFee'), inv.mgmt_fee],
    [t('adminFee'), inv.admin_fee],
    [t('serviceFee'), inv.service_fee],
    [t('tax'), inv.tax],
  ];

  const bankBlock = bankReady ? (
    <div className="flex flex-col gap-3">
      <CopyField label={t('bankName')} value={pay.bank.bank} copyLabel={t('copy')} copiedLabel={t('copied')} />
      <CopyField label={t('bankNumber')} value={pay.bank.number} copyLabel={t('copy')} copiedLabel={t('copied')} mono />
      <CopyField label={t('bankHolder')} value={pay.bank.name} copyLabel={t('copy')} copiedLabel={t('copied')} />
      <CopyField label={t('reference')} value={inv.number} copyLabel={t('copy')} copiedLabel={t('copied')} mono />
      <Alert tone="warn">{t('referenceNote', { number: inv.number, total: idr(inv.total) })}</Alert>
    </div>
  ) : (
    <Alert tone="warn" title={t('bankMissingTitle')}>{t('bankMissingBody')}</Alert>
  );

  return (
    <Card id="invoice" padding="none" className="overflow-hidden">
      <CardHeader className="px-5 pt-5 md:px-6 md:pt-6" actions={<Button href={`/${orgId}/billing`} linkAs={Link} variant="ghost" size="sm" iconLeft="close">{t('closeDetail')}</Button>}>
        <CardTitle className="flex flex-wrap items-center gap-2">
          <span className="font-mono tnum">{inv.number}</span>
          <Badge tone={st.tone}>{t(`status.${st.key}`)}</Badge>
        </CardTitle>
        <CardDescription>
          {t(`kind.${inv.kind}`)}
          {campaignTitle ? ` · ${campaignTitle}` : ''}
          {inv.pin_until ? ` · ${t('pinUntil', { date: formatDate(inv.pin_until, loc) })}` : ''}
        </CardDescription>
      </CardHeader>
      <CardContent className="grid grid-cols-1 gap-6 px-5 pb-6 md:grid-cols-2 md:px-6 [&>*]:min-w-0">
        <div className="flex flex-col gap-4">
          <dl className="grid grid-cols-2 gap-3 text-body-s [&>*]:min-w-0">
            <div>
              <dt className="text-muted">{t('issuedAt')}</dt>
              <dd className="font-semibold text-ink">{inv.issued_at ? formatDateTime(inv.issued_at, loc) : '—'}</dd>
            </div>
            <div>
              <dt className="text-muted">{t('dueAt')}</dt>
              <dd className="font-semibold text-ink">{inv.due_at ? formatDateTime(inv.due_at, loc) : '—'}</dd>
            </div>
          </dl>
          <table className="w-full text-body-s">
            <caption className="sr-only">{t('breakdown')}</caption>
            <tbody>
              {lines.map(([label, v]) =>
                v ? (
                  <tr key={label} className="border-b border-border">
                    <th scope="row" className="py-2 text-left font-normal text-muted">{label}</th>
                    <td className="py-2 text-right text-ink tnum">{idr(v)}</td>
                  </tr>
                ) : null,
              )}
              <tr>
                <th scope="row" className="pt-3 text-left text-h6 text-ink">{t('total')}</th>
                <td className="pt-3 text-right text-h5 text-ink tnum">{idr(inv.total)}</td>
              </tr>
            </tbody>
          </table>
          {inv.status === 'paid' ? (
            <Alert tone="success" title={t('paidTitle')}>
              {t('paidBody', {
                date: inv.paid_at ? formatDateTime(inv.paid_at, loc) : '—',
                amount: idr(inv.paid_amount ?? inv.total),
                channel: inv.payment_channel ? t(`channel.${inv.payment_channel}`) : '—',
              })}
            </Alert>
          ) : null}
          {inv.status === 'paid' ? (
            inv.faktur_no ? (
              <div className="flex flex-col gap-1.5">
                <Button variant="secondary" iconLeft="download" disabled className="self-start">{t('fakturDownload')}</Button>
                <p className="text-caption text-muted">{t('fakturPending', { no: inv.faktur_no })}</p>
              </div>
            ) : (
              <p className="text-caption text-muted">{t('fakturNotYet')}</p>
            )
          ) : null}
        </div>

        {inv.status === 'issued' ? (
          <div className="flex flex-col gap-4 rounded-card-sm bg-subtle p-4">
            <p className="text-h6 text-ink">{useQris ? t('payQris') : t('payTransfer')}</p>
            {useQris ? (
              qris ? (
                <div className="flex flex-col items-center gap-3">
                  <QrCode value={qris} label={t('qrisLabel', { number: inv.number, total: idr(inv.total) })} />
                  <p className="text-center text-body-s text-text-2">{t('qrisHint', { total: idr(inv.total) })}</p>
                </div>
              ) : (
                <>
                  <Alert tone="warn" title={t('qrisMissingTitle')}>{t('qrisMissingBody')}</Alert>
                  {bankBlock}
                </>
              )
            ) : (
              <>
                <p className="text-body-s text-muted">{t('overQris', { max: idr(pay.qrisMax) })}</p>
                {bankBlock}
              </>
            )}
            <p className="text-caption text-muted">{t('confirmNote')}</p>
          </div>
        ) : null}
      </CardContent>
    </Card>
  );
}
