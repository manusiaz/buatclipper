'use client';

import { useRouter } from 'next/navigation';
import { useState, useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { Alert, Button, Card, CardContent, CardDescription, CardHeader, CardTitle, Field, Input, RadioGroup, formatDateTime, formatIDR, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { buyPin } from './actions';

const PRESETS = ['7', '14', '30'];

export function PinPanel({
  orgId,
  campaignId,
  pricePerWeek,
  pinnedUntil,
  canBuy,
  canBilling,
  running,
}: {
  orgId: string;
  campaignId: string;
  pricePerWeek: number;
  pinnedUntil: string | null;
  canBuy: boolean;
  canBilling: boolean;
  running: boolean;
}) {
  const t = useTranslations('brand.pin');
  const errText = useErrorText();
  const router = useRouter();
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [choice, setChoice] = useState('7');
  const [custom, setCustom] = useState('');
  const [pending, start] = useTransition();
  const days = choice === 'custom' ? Number.parseInt(custom, 10) : Number(choice);
  const valid = Number.isInteger(days) && days >= 1 && days <= 90;
  const price = valid ? Math.ceil(days / 7) * pricePerWeek : 0;
  const active = pinnedUntil && new Date(pinnedUntil).getTime() > Date.now();

  return (
    <Card className="max-w-[640px]">
      <CardHeader>
        <CardTitle>{t('title')}</CardTitle>
        <CardDescription>{t('description', { price: formatIDR(pricePerWeek, { locale }) })}</CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        {active ? <Alert tone="success">{t('activeUntil', { date: formatDateTime(pinnedUntil, locale) })}</Alert> : null}
        {!running ? (
          <Alert tone="info">{t('notRunning')}</Alert>
        ) : !canBuy ? (
          <Alert tone="info">{t('readOnly')}</Alert>
        ) : (
          <form
            className="flex flex-col gap-4"
            onSubmit={(e) => {
              e.preventDefault();
              if (!valid) return;
              start(async () => {
                const res = await buyPin(orgId, campaignId, days);
                if (!res.ok) return void toast.error(errText(res.error));
                toast.success(t('invoiced'));
                if (canBilling) router.push(`/${orgId}/billing?invoice=${res.invoiceId}`);
              });
            }}
          >
            <RadioGroup
              name="pin_days"
              legend={t('duration')}
              legendVisible
              orientation="horizontal"
              variant="card"
              value={choice}
              onValueChange={setChoice}
              options={[
                ...PRESETS.map((d) => ({ value: d, label: t('days', { count: Number(d) }), aside: formatIDR(Math.ceil(Number(d) / 7) * pricePerWeek, { locale }) })),
                { value: 'custom', label: t('custom') },
              ]}
            />
            {choice === 'custom' ? (
              <Field label={t('customDays')} helper={t('customHelp')} error={custom && !valid ? t('customInvalid') : undefined}>
                <Input type="number" inputMode="numeric" min={1} max={90} value={custom} onChange={(e) => setCustom(e.target.value)} suffix={t('daysUnit')} />
              </Field>
            ) : null}
            <div className="flex flex-wrap items-center justify-between gap-3 rounded-card-sm bg-subtle px-4 py-3">
              <span className="text-body-s text-muted">{t('total')}</span>
              <span className="text-h5 text-ink tnum">{formatIDR(price, { locale })}</span>
            </div>
            <p className="text-caption text-muted">{t('note')}</p>
            <Button type="submit" variant="ink" loading={pending} disabled={!valid} iconLeft="push_pin" className="self-start">
              {t('submit')}
            </Button>
          </form>
        )}
      </CardContent>
    </Card>
  );
}
