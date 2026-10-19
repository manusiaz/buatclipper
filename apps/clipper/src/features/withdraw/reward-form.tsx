'use client';

// C6.1: klaim reward non-tunai. Field non-PII (User ID, Zone ID…) diisi di sini; field PII (alamat/HP) hanya di
// accounts.{domain}/payout-methods; recipient_ref dari identity api.my_recipients (atau ?recipient_ref setelah kembali).
import { useMemo, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useLocale, useTranslations } from 'next-intl';
import { Alert, Badge, Button, Card, CardDescription, CardHeader, CardTitle, Field, Icon, Input, formatNumber, toast } from '@clipper/ui';
import type { RecipientField } from '../lib/pure';
import { requestFulfillment } from './actions';

export interface RewardOption {
  id: string;
  name: string;
  unitLabel: string;
  decimals: number;
  fulfillment: string;
  available: number;
  fields: RecipientField[];
  recipientRef: string | null;
  recipientHref: string;
}

export function RewardForm({ option, disabled }: { option: RewardOption; disabled: boolean }) {
  const t = useTranslations('clipper.withdraw.reward');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const router = useRouter();
  const fixed = option.fulfillment === 'code_pool';
  const [raw, setRaw] = useState(fixed ? '1' : '');
  const [values, setValues] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const idem = useMemo(() => crypto.randomUUID(), []);

  const inline = option.fields.filter((f) => !f.pii);
  const needsRef = option.fields.some((f) => f.pii);
  const amount = Number(raw.replace(',', '.')) || 0;
  const step = 1 / 10 ** option.decimals;
  const missing = inline.some((f) => f.required && !values[f.key]?.trim());
  const valid =
    !disabled && amount > 0 && amount <= option.available && !missing && (!needsRef || !!option.recipientRef) && (!fixed || amount === 1);

  const submit = () =>
    start(async () => {
      setError(null);
      const r = await requestFulfillment({
        rewardType: option.id,
        amount,
        recipient: values,
        recipientRef: option.recipientRef,
        idempotency: idem,
      });
      if (!r.ok) return setError(r.message);
      toast.success(t('success'), { description: t('successBody') });
      router.push('/wallet?tab=reward');
    });

  return (
    <Card>
      <CardHeader actions={<Badge tone="success">{`${formatNumber(option.available, locale, { maximumFractionDigits: option.decimals })} ${option.unitLabel}`}</Badge>}>
        <CardTitle>{option.name}</CardTitle>
        <CardDescription>{t(`mode.${option.fulfillment}`)}</CardDescription>
      </CardHeader>
      <form
        className="flex flex-col gap-3"
        onSubmit={(e) => {
          e.preventDefault();
          if (valid) submit();
        }}
      >
        {error ? <Alert tone="danger">{error}</Alert> : null}
        {fixed ? (
          <p className="text-caption text-muted">{t('onePerCode')}</p>
        ) : (
          <Field label={t('amount', { unit: option.unitLabel })} error={amount > option.available ? t('aboveBalance') : undefined}>
            <Input
              type="number"
              inputMode="decimal"
              min={step}
              step={step}
              max={option.available}
              value={raw}
              onChange={(e) => setRaw(e.target.value)}
              suffix={option.unitLabel}
            />
          </Field>
        )}
        {inline.map((f) => (
          <Field key={f.key} label={f.label} required={f.required} optional={!f.required}>
            <Input
              value={values[f.key] ?? ''}
              maxLength={200}
              autoComplete="off"
              onChange={(e) => setValues((v) => ({ ...v, [f.key]: e.target.value }))}
            />
          </Field>
        ))}
        {needsRef ? (
          option.recipientRef ? (
            <p className="flex items-center gap-2 rounded-chip bg-success-bg px-3 py-2 text-caption font-semibold text-success-fg">
              <Icon name="check_circle" size={16} filled />
              {t('recipientSaved')}
              <a href={option.recipientHref} className="ml-auto underline">
                {t('change')}
              </a>
            </p>
          ) : (
            <Alert tone="info" title={t('recipientTitle')} action={{ label: t('recipientAction'), href: option.recipientHref }}>
              {t('recipientBody', { fields: option.fields.filter((f) => f.pii).map((f) => f.label).join(', ') })}
            </Alert>
          )
        ) : null}
        <Button type="submit" fullWidth iconLeft="redeem" loading={pending} disabled={!valid}>
          {t('submit')}
        </Button>
      </form>
    </Card>
  );
}
