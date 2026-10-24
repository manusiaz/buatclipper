'use client';

import { useState, useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { Alert, Button, Card, CardContent, CardDescription, CardHeader, CardTitle, Dialog, DialogContent, Field, Input, formatIDR, randomId, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { requestRefund } from './actions';
import { emptyDest, RefundDestFields, toDest, type RefundDestConfig } from './refund-dest';

export interface LeftoverRow {
  campaignId: string;
  title: string;
  leftover: number;
}

type Mode = 'rollover' | 'refund';

export function LeftoverPanel({
  orgId,
  rows,
  aal2,
  securityHref,
  refundFee,
  dest: destConfig,
}: {
  orgId: string;
  rows: LeftoverRow[];
  aal2: boolean;
  securityHref: string;
  /** public.finance.refund_transfer_fee_idr */
  refundFee: number;
  dest: RefundDestConfig;
}) {
  const t = useTranslations('brand.leftover');
  const errText = useErrorText();
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [dialog, setDialog] = useState<{ row: LeftoverRow; mode: Mode; key: string } | null>(null);
  const [amount, setAmount] = useState('');
  const [destDraft, setDestDraft] = useState(() => emptyDest(destConfig));
  const [pending, start] = useTransition();
  const value = Number(amount);
  const dest = toDest(destConfig, destDraft);
  const valid = dialog != null && Number.isInteger(value) && value > 0 && value <= Math.floor(dialog.row.leftover) && (dialog.mode === 'rollover' || (value > refundFee && dest != null));

  const openDialog = (row: LeftoverRow, mode: Mode) => {
    setAmount(String(Math.floor(row.leftover)));
    setDialog({ row, mode, key: randomId() });
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>{t('title')}</CardTitle>
        <CardDescription>{t('description')}</CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        {!aal2 ? <Alert tone="info">{t('mfaNote')}</Alert> : null}
        <ul className="flex flex-col divide-y divide-border">
          {rows.map((r) => (
            <li key={r.campaignId} className="flex flex-col gap-3 py-3 sm:flex-row sm:items-center">
              <div className="min-w-0 flex-1">
                <p className="truncate text-body-s font-bold text-ink">{r.title}</p>
                <p className="text-caption text-muted">{t('amountLeft', { amount: formatIDR(r.leftover, { locale }) })}</p>
              </div>
              <div className="flex gap-2">
                {aal2 ? (
                  <>
                    <Button variant="secondary" size="sm" iconLeft="refresh" onClick={() => openDialog(r, 'rollover')}>{t('rollover')}</Button>
                    <Button variant="ink" size="sm" iconLeft="account_balance" onClick={() => openDialog(r, 'refund')}>{t('refund')}</Button>
                  </>
                ) : (
                  <Button href={securityHref} variant="secondary" size="sm" iconLeft="shield">{t('setupMfa')}</Button>
                )}
              </div>
            </li>
          ))}
        </ul>
        <p className="text-caption text-muted">{t('note')}</p>
      </CardContent>

      <Dialog open={!!dialog} onOpenChange={(o) => !o && setDialog(null)}>
        <DialogContent
          title={dialog ? t(`${dialog.mode}Title`) : ''}
          description={dialog ? t(`${dialog.mode}Body`) : undefined}
          footer={
            <>
              <Button variant="secondary" onClick={() => setDialog(null)}>{t('cancel')}</Button>
              <Button
                variant="ink"
                loading={pending}
                disabled={!valid}
                onClick={() =>
                  dialog &&
                  start(async () => {
                    const res = await requestRefund(orgId, dialog.row.campaignId, dialog.mode, value, dialog.key, dest ?? undefined);
                    if (!res.ok) return void toast.error(errText(res.error));
                    toast.success(t(`${dialog.mode}Done`));
                    setDialog(null);
                  })
                }
              >
                {t('confirm')}
              </Button>
            </>
          }
        >
          {dialog ? (
            <div className="flex flex-col gap-3">
              <Field
                label={t('amount')}
                helper={t('amountHelp', { max: formatIDR(Math.floor(dialog.row.leftover), { locale }) })}
                error={amount && !valid ? t('amountInvalid') : undefined}
              >
                <Input type="number" inputMode="numeric" min={1} max={Math.floor(dialog.row.leftover)} step={1} prefix="Rp" value={amount} onChange={(e) => setAmount(e.target.value)} />
              </Field>
              {dialog.mode === 'refund' ? (
                <dl className="grid grid-cols-2 gap-2 rounded-card-sm bg-subtle p-3 text-body-s">
                  <dt className="text-muted">{t('transferFee')}</dt>
                  <dd className="text-right text-ink tnum">{formatIDR(refundFee, { locale })}</dd>
                  <dt className="font-semibold text-ink">{t('received')}</dt>
                  <dd className="text-right font-semibold text-ink tnum">{formatIDR(Math.max(0, (valid ? value : 0) - refundFee), { locale })}</dd>
                </dl>
              ) : null}
              {dialog.mode === 'refund' ? <RefundDestFields config={destConfig} value={destDraft} onChange={setDestDraft} /> : null}
            </div>
          ) : null}
        </DialogContent>
      </Dialog>
    </Card>
  );
}
