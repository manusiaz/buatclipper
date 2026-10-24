'use client';

import { useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, CopyField } from '@clipper/ui';
import { useErrorText } from '@/features/shared/use-error-text';
import { revealRefundDest, type RefundDestination } from './actions';

/** Rekening pribadi pemilik org perorangan: dibuka sekali per klik (diaudit di identity), tidak disimpan di halaman. */
export function RefundDestReveal({ refundId }: { refundId: string }) {
  const t = useTranslations('admin.finance');
  const errorText = useErrorText();
  const [pending, start] = useTransition();
  const [dest, setDest] = useState<RefundDestination | null>(null);
  const [error, setError] = useState<string | null>(null);
  if (dest) {
    return (
      <div className="flex min-w-[240px] flex-col gap-1 text-left">
        <CopyField value={dest.account_no} label={`${dest.bank_code} · ${dest.account_name}`} mono copyLabel={t('copy')} copiedLabel={t('copied')} />
        <span className="text-caption text-muted">{t('refundDestNet', { amount: dest.amount })}</span>
      </div>
    );
  }
  return (
    <span className="inline-flex flex-col items-end gap-1">
      <Button
        size="sm"
        variant="secondary"
        iconLeft="visibility"
        loading={pending}
        onClick={() =>
          start(async () => {
            const r = await revealRefundDest(refundId);
            if (r.ok && r.data) setDest(r.data);
            else setError(errorText(r.ok ? 'generic' : r.error));
          })
        }
      >
        {t('refundDestReveal')}
      </Button>
      {error ? <Alert tone="danger">{error}</Alert> : null}
    </span>
  );
}
