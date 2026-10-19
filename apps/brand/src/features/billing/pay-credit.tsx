'use client';

import { useState, useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { Button, ConfirmDialog, Field, Input, formatIDR, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { applyInvoiceCredit } from './actions';

/**
 * Kredit org di invoice issued: pakai sebagian/penuh (penuh = lunas, tidak bisa dibatalkan) atau lepas cadangan.
 * Butuh aal2; tanpa MFA tombol membawa ke accounts/security lalu kembali.
 */
export function InvoiceCredit({
  orgId,
  invoiceId,
  number,
  total,
  applied,
  cap,
  aal2,
  securityHref,
}: {
  orgId: string;
  invoiceId: string;
  number: string;
  total: number;
  /** credit_applied saat ini */
  applied: number;
  /** min(kredit tersedia + applied, total) */
  cap: number;
  aal2: boolean;
  securityHref: string;
}) {
  const t = useTranslations('brand.credit');
  const errText = useErrorText();
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [amount, setAmount] = useState(String(cap));
  const [pending, start] = useTransition();
  const idr = (v: number) => formatIDR(v, { locale, fractionDigits: Number.isInteger(v) ? 0 : 2 });
  const value = Number(amount);
  const valid = amount.trim() !== '' && Number.isFinite(value) && value > 0 && value <= cap && Math.round(value * 100) === value * 100;
  const full = valid && value === total;

  const run = (next: number) =>
    new Promise<void>((resolve) =>
      start(async () => {
        const res = await applyInvoiceCredit(orgId, invoiceId, next);
        resolve();
        if (!res.ok) return void toast.error(errText(res.error));
        if (res.paid) toast.success(t('paid', { number }));
        else if (res.creditApplied === 0) toast.success(t('released'));
        else toast.success(t('appliedToast', { applied: idr(res.creditApplied), due: idr(res.due) }));
      }),
    );

  const summary = applied > 0 ? <p className="text-body-s font-semibold text-ink">{t('applied', { applied: idr(applied), due: idr(total - applied) })}</p> : null;

  if (!aal2) {
    return (
      <div className="flex flex-col gap-2">
        {summary}
        <Button href={securityHref} variant="secondary" iconLeft="shield" className="self-start">{t('payNeedsMfa')}</Button>
        <p className="text-caption text-muted">{t('mfaNote')}</p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      {summary}
      {cap > 0 ? (
        <Field
          label={t('applyAmount')}
          helper={t('applyHelp', { max: idr(cap) })}
          error={amount && !valid ? t('amountInvalid', { max: idr(cap) }) : undefined}
        >
          <Input type="number" inputMode="decimal" min={0} max={cap} step="any" prefix="Rp" value={amount} onChange={(e) => setAmount(e.target.value)} />
        </Field>
      ) : null}
      <div className="flex flex-wrap gap-2">
        {cap > 0 ? (
          <ConfirmDialog
            trigger={<Button variant="ink" iconLeft="account_balance_wallet" disabled={!valid} loading={pending}>{t('apply')}</Button>}
            title={full ? t('payTitle', { number }) : t('applyTitle', { number })}
            description={full ? t('payBody', { total: idr(total) }) : t('applyBody', { applied: idr(value || 0), due: idr(Math.max(0, total - (value || 0))) })}
            confirmLabel={full ? t('payConfirm') : t('applyConfirm')}
            cancelLabel={t('cancel')}
            tone="ink"
            loading={pending}
            onConfirm={() => run(value)}
          />
        ) : null}
        {applied > 0 ? (
          <Button variant="secondary" iconLeft="undo" loading={pending} onClick={() => void run(0)}>
            {t('release')}
          </Button>
        ) : null}
      </div>
    </div>
  );
}
