'use client';

import { useState, useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { Alert, Button, Card, CardContent, CardDescription, CardHeader, CardTitle, Dialog, DialogContent, Field, Input, formatIDR, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { requestRefund } from './actions';

export interface LeftoverRow {
  campaignId: string;
  title: string;
  leftover: number;
}

type Mode = 'rollover' | 'refund';

export function LeftoverPanel({ orgId, rows, aal2, securityHref }: { orgId: string; rows: LeftoverRow[]; aal2: boolean; securityHref: string }) {
  const t = useTranslations('brand.leftover');
  const errText = useErrorText();
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [dialog, setDialog] = useState<{ row: LeftoverRow; mode: Mode; key: string } | null>(null);
  const [amount, setAmount] = useState('');
  const [pending, start] = useTransition();
  const value = Number(amount);
  const valid = dialog != null && Number.isInteger(value) && value > 0 && value <= Math.floor(dialog.row.leftover);

  const openDialog = (row: LeftoverRow, mode: Mode) => {
    setAmount(String(Math.floor(row.leftover)));
    setDialog({ row, mode, key: crypto.randomUUID() });
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
                <p className="text-caption text-muted">{t('estimate', { amount: formatIDR(r.leftover, { locale }) })}</p>
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
                    const res = await requestRefund(orgId, dialog.row.campaignId, dialog.mode, value, dialog.key);
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
            <Field
              label={t('amount')}
              helper={t('amountHelp', { max: formatIDR(Math.floor(dialog.row.leftover), { locale }) })}
              error={amount && !valid ? t('amountInvalid') : undefined}
            >
              <Input type="number" inputMode="numeric" min={1} max={Math.floor(dialog.row.leftover)} step={1} prefix="Rp" value={amount} onChange={(e) => setAmount(e.target.value)} />
            </Field>
          ) : null}
        </DialogContent>
      </Dialog>
    </Card>
  );
}
