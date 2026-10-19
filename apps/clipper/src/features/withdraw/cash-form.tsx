'use client';

// C1.11 / C6.3: pilih rekening (tersamar) + jumlah + Batch (gratis) / Instant (biaya flat) → request_payout.
import { useMemo, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useLocale, useTranslations } from 'next-intl';
import { Alert, Button, Field, Input, RadioGroup, formatIDR, formatNumber, toast } from '@clipper/ui';
import { requestPayout } from './actions';

export interface MethodOption {
  id: string;
  bank: string;
  last4: string;
  name: string;
  kind: string;
}

export function CashForm({
  methods,
  available,
  min,
  fee,
  instant,
  nextBatch,
  disabled,
  initialMethod,
}: {
  methods: MethodOption[];
  available: number;
  min: number;
  fee: number;
  instant: { enabled: boolean; reason: string | null };
  nextBatch: string;
  disabled: boolean;
  initialMethod?: string;
}) {
  const t = useTranslations('clipper.withdraw');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const router = useRouter();
  const [method, setMethod] = useState(methods.find((m) => m.id === initialMethod)?.id ?? methods[0]?.id ?? '');
  const [raw, setRaw] = useState(available >= min ? String(Math.floor(available)) : '');
  const [channel, setChannel] = useState<'batch' | 'instant'>('batch');
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  // Satu kunci per percobaan form: kirim ulang setelah error jaringan tidak membuat payout kedua.
  const idem = useMemo(() => crypto.randomUUID(), []);

  const amount = Number(raw.replace(/\D/g, '')) || 0;
  const chargedFee = channel === 'instant' ? fee : 0;
  const tooLow = amount > 0 && amount < min;
  const tooHigh = amount > available;
  const valid = !!method && amount >= min && !tooHigh && amount - chargedFee > 0 && !disabled;

  const submit = () =>
    start(async () => {
      setError(null);
      const r = await requestPayout({ method, amount, channel, idempotency: idem });
      if (!r.ok) return setError(r.message);
      toast.success(t('success'), {
        description: channel === 'instant' ? t('successInstant') : t('successBatch', { date: nextBatch }),
      });
      router.push('/wallet');
    });

  return (
    <form
      className="flex flex-col gap-4"
      onSubmit={(e) => {
        e.preventDefault();
        if (valid) submit();
      }}
    >
      {error ? <Alert tone="danger">{error}</Alert> : null}
      <RadioGroup
        name="method"
        legend={t('method')}
        legendVisible
        variant="card"
        value={method}
        onValueChange={setMethod}
        options={methods.map((m) => ({
          value: m.id,
          label: `${m.bank.toUpperCase()} **${m.last4}`,
          description: m.name,
          aside: m.kind === 'ewallet' ? t('ewallet') : undefined,
        }))}
      />
      <Field
        label={t('amount')}
        helper={t('amountHelper', { min: formatIDR(min, { locale }), max: formatIDR(available, { locale }) })}
        error={tooLow ? t('belowMin', { min: formatIDR(min, { locale }) }) : tooHigh ? t('aboveBalance') : undefined}
        labelAside={
          <Button type="button" variant="link" size="sm" onClick={() => setRaw(String(Math.floor(available)))}>
            {t('all')}
          </Button>
        }
      >
        <Input
          inputMode="numeric"
          prefix="Rp"
          value={amount ? formatNumber(amount, locale) : ''}
          onChange={(e) => setRaw(e.target.value)}
          className="tnum"
          autoComplete="off"
        />
      </Field>
      <RadioGroup
        name="channel"
        legend={t('channel')}
        legendVisible
        variant="card"
        value={channel}
        onValueChange={(v) => setChannel(v as 'batch' | 'instant')}
        options={[
          { value: 'batch', label: t('batch'), description: t('batchBody', { date: nextBatch }), aside: t('free') },
          {
            value: 'instant',
            label: t('instant'),
            description: instant.enabled ? t('instantBody') : instant.reason ?? t('instantOff'),
            aside: formatIDR(fee, { locale }),
            disabled: !instant.enabled,
          },
        ]}
      />
      <dl className="grid grid-cols-[1fr_auto] gap-y-1.5 rounded-card-sm bg-subtle p-3 text-body-s">
        <dt className="text-muted">{t('sumAmount')}</dt>
        <dd className="text-right font-semibold tnum">{formatIDR(amount, { locale })}</dd>
        <dt className="text-muted">{t('sumFee')}</dt>
        <dd className="text-right font-semibold tnum">{chargedFee ? `−${formatIDR(chargedFee, { locale })}` : t('free')}</dd>
        <dt className="font-bold text-ink">{t('sumReceive')}</dt>
        <dd className="text-right text-body font-extrabold tnum">{formatIDR(Math.max(0, amount - chargedFee), { locale })}</dd>
      </dl>
      <Button type="submit" variant="ink" size="lg" fullWidth iconLeft="payments" loading={pending} disabled={!valid}>
        {t('submit')}
      </Button>
    </form>
  );
}
