'use client';

import { useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, Field, Input, RadioGroup, Select, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error-text';
import { addPayoutMethod } from './actions';
import { BANKS, EWALLETS, normalizeAccountNo, sameName, type MethodKind } from './rules';

export function AddMethodForm({ kycName, next }: { kycName: string; next?: string }) {
  const t = useTranslations('accounts.payout');
  const errText = useErrorText();
  const [kind, setKind] = useState<MethodKind>('bank');
  const [bankCode, setBankCode] = useState('');
  const [accountNo, setAccountNo] = useState('');
  const [accountName, setAccountName] = useState(kycName);
  const [error, setError] = useState<string | null>(null);
  const [leaving, setLeaving] = useState(false);
  const [pending, start] = useTransition();

  const normalized = normalizeAccountNo(kind, accountNo);
  const nameOk = !!kycName && sameName(accountName, kycName);
  const ready = !!bankCode && !!normalized && nameOk;

  const submit = () =>
    start(async () => {
      setError(null);
      const r = await addPayoutMethod({ kind, bankCode, accountNo: normalized!, accountName: accountName.trim(), next });
      if (!r.ok) return setError(r.error);
      if (r.redirect) {
        setLeaving(true);
        return window.location.assign(r.redirect);
      }
      toast.success(t('added'));
      setBankCode('');
      setAccountNo('');
    });

  return (
    <form
      className="flex flex-col gap-5"
      onSubmit={(e) => {
        e.preventDefault();
        if (ready) submit();
      }}
    >
      {error && <Alert tone="danger">{errText(error)}</Alert>}
      <RadioGroup
        name="kind"
        legend={t('kind')}
        legendVisible
        variant="card"
        orientation="horizontal"
        value={kind}
        onValueChange={(v) => {
          setKind(v as MethodKind);
          setBankCode('');
        }}
        options={[
          { value: 'bank', label: t('kindBank') },
          { value: 'ewallet', label: t('kindEwallet') },
        ]}
      />
      <Field label={kind === 'bank' ? t('bank') : t('ewallet')} required>
        <Select
          value={bankCode}
          onValueChange={setBankCode}
          placeholder={t('choose')}
          options={(kind === 'bank' ? BANKS : EWALLETS).map((b) => ({ value: b.code, label: b.name }))}
        />
      </Field>
      <Field
        label={kind === 'bank' ? t('accountNo') : t('phone')}
        required
        helper={kind === 'bank' ? t('accountNoHelper') : t('phoneHelper')}
        error={accountNo && !normalized ? (kind === 'bank' ? t('accountNoInvalid') : t('phoneInvalid')) : undefined}
      >
        <Input
          value={accountNo}
          onChange={(e) => setAccountNo(e.target.value.replace(/[^\d\s.+-]/g, ''))}
          inputMode={kind === 'bank' ? 'numeric' : 'tel'}
          autoComplete="off"
          maxLength={24}
          className="tnum"
        />
      </Field>
      <Field
        label={t('holder')}
        required
        helper={t('holderHelper', { name: kycName })}
        error={accountName && !nameOk ? t('holderMismatch', { name: kycName }) : undefined}
      >
        <Input value={accountName} onChange={(e) => setAccountName(e.target.value)} maxLength={100} autoComplete="name" />
      </Field>
      <Button type="submit" size="lg" fullWidth loading={pending || leaving} disabled={!ready}>
        {t('save')}
      </Button>
    </form>
  );
}
