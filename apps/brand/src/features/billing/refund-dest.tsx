'use client';

import { useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, Dialog, DialogContent, DialogTrigger, Field, Input, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { setRefundDest } from './actions';

/** AB-6 rekening tujuan refund. Badan: rekening perusahaan a.n. nama legal; perorangan: rekening bank pribadi pemilik yang
 * terdaftar di Akun — dipilih identity saat finance membukanya, app brand tidak membaca data identity (invarian 1). */
export interface RefundDestConfig {
  kind: 'badan' | 'perorangan';
  legalName: string;
  ownerDirect: boolean;
  /** accounts …/payout-methods (kelola rekening pribadi pemilik). */
  methodsHref: string;
}

export type RefundDest = { bank: string; account_no: string; account_name: string } | { owner_account: true };
type Draft = { bank: string; account_no: string; account_name: string };

export const emptyDest = (c: RefundDestConfig): Draft => ({ bank: '', account_no: '', account_name: c.legalName });

export function toDest(c: RefundDestConfig, d: Draft): RefundDest | null {
  if (c.kind === 'perorangan') return c.ownerDirect ? { owner_account: true } : null;
  const acct = d.account_no.replace(/[\s.-]/g, '');
  return d.bank.trim().length >= 2 && /^\d{5,20}$/.test(acct) && d.account_name.trim() ? { bank: d.bank.trim(), account_no: acct, account_name: d.account_name.trim() } : null;
}

export function RefundDestFields({ config: c, value: d, onChange }: { config: RefundDestConfig; value: Draft; onChange: (d: Draft) => void }) {
  const t = useTranslations('brand.refundDest');
  const set = (k: keyof Draft, v: string) => onChange({ ...d, [k]: v });
  if (c.kind === 'perorangan') {
    return c.ownerDirect ? (
      <Alert tone="info" action={{ label: t('manageMethods'), href: c.methodsHref }}>{t('ownerAccount')}</Alert>
    ) : (
      <Alert tone="info">{t('ownerOnly')}</Alert>
    );
  }
  return (
    <div className="flex flex-col gap-3">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 [&>*]:min-w-0">
        <Field label={t('bank')} required>
          <Input value={d.bank} onChange={(e) => set('bank', e.target.value)} maxLength={40} placeholder="BCA" />
        </Field>
        <Field label={t('accountNo')} required>
          <Input inputMode="numeric" value={d.account_no} onChange={(e) => set('account_no', e.target.value)} maxLength={24} />
        </Field>
      </div>
      <Field label={t('accountName')} helper={t('accountNameHelp', { name: c.legalName })} required>
        <Input value={d.account_name} onChange={(e) => set('account_name', e.target.value)} maxLength={200} />
      </Field>
    </div>
  );
}

/** Refund yang belum punya rekening (mis. dibuat otomatis saat campaign dibatalkan). */
export function RefundDestDialog({ orgId, refundId, config }: { orgId: string; refundId: string; config: RefundDestConfig }) {
  const t = useTranslations('brand.refundDest');
  const errText = useErrorText();
  const [open, setOpen] = useState(false);
  const [d, setD] = useState(() => emptyDest(config));
  const [pending, start] = useTransition();
  const dest = toDest(config, d);
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button size="sm" variant="secondary" iconLeft="account_balance">{t('fill')}</Button>
      </DialogTrigger>
      <DialogContent
        title={t('title')}
        description={t('body')}
        footer={
          <>
            <Button variant="secondary" onClick={() => setOpen(false)}>{t('cancel')}</Button>
            <Button
              loading={pending}
              disabled={!dest}
              onClick={() =>
                dest &&
                start(async () => {
                  const res = await setRefundDest(orgId, refundId, dest);
                  if (!res.ok) return void toast.error(errText(res.error));
                  toast.success(t('saved'));
                  setOpen(false);
                })
              }
            >
              {t('save')}
            </Button>
          </>
        }
      >
        <RefundDestFields config={config} value={d} onChange={setD} />
      </DialogContent>
    </Dialog>
  );
}
