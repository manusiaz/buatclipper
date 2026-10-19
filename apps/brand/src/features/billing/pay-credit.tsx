'use client';

import { useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { Button, ConfirmDialog, formatIDR, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { payInvoiceWithCredit } from './actions';

/** "Bayar pakai kredit": butuh aal2; tanpa MFA tombol membawa ke accounts/security lalu kembali. */
export function PayWithCredit({
  orgId,
  invoiceId,
  number,
  total,
  available,
  aal2,
  securityHref,
}: {
  orgId: string;
  invoiceId: string;
  number: string;
  total: number;
  available: number;
  aal2: boolean;
  securityHref: string;
}) {
  const t = useTranslations('brand.credit');
  const errText = useErrorText();
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [pending, start] = useTransition();
  const idr = (v: number) => formatIDR(v, { locale, fractionDigits: Number.isInteger(v) ? 0 : 2 });

  if (!aal2) {
    return (
      <div className="flex flex-col gap-1.5">
        <Button href={securityHref} variant="secondary" iconLeft="shield">{t('payNeedsMfa')}</Button>
        <p className="text-caption text-muted">{t('mfaNote')}</p>
      </div>
    );
  }
  return (
    <ConfirmDialog
      trigger={<Button variant="ink" iconLeft="account_balance_wallet" loading={pending}>{t('pay')}</Button>}
      title={t('payTitle', { number })}
      description={t('payBody', { total: idr(total), rest: idr(available - total) })}
      confirmLabel={t('payConfirm')}
      cancelLabel={t('cancel')}
      tone="ink"
      loading={pending}
      onConfirm={() =>
        new Promise<void>((resolve) =>
          start(async () => {
            const res = await payInvoiceWithCredit(orgId, invoiceId);
            resolve();
            if (!res.ok) return void toast.error(errText(res.error));
            toast.success(t('paid', { number }));
          }),
        )
      }
    />
  );
}
