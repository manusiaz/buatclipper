'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useState, useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { fromWibInput, toWibInput } from '@clipper/campaign-builder';
import {
  Alert,
  Button,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  ConfirmDialog,
  Field,
  Input,
  Select,
  formatDateTime,
  formatNumber,
  platformLabel,
  toast,
  type Platform,
} from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { controlCampaign, type ControlAction } from './actions';

export interface ControlRule {
  id: string;
  kind: string;
  platform: string | null;
  code: string;
  unitLabel: string;
  params: Record<string, unknown>;
}

export interface ControlPool {
  poolId: string;
  code: string;
  unitLabel: string;
  decimals: number;
}

const RUNNING = ['scheduled', 'live', 'paused'];
const num = (v: unknown) => (typeof v === 'number' ? v : typeof v === 'string' && v !== '' ? Number(v) : NaN);
type Tier = { from: number; to: number | null; rate: number };

export function ControlPanel({
  orgId,
  campaignId,
  title,
  status,
  submitDeadline,
  rules,
  pools,
  canControl,
  canFund,
}: {
  orgId: string;
  campaignId: string;
  title: string;
  status: string;
  submitDeadline: string | null;
  rules: ControlRule[];
  pools: ControlPool[];
  canControl: boolean;
  canFund: boolean;
}) {
  const t = useTranslations('brand.controls');
  const tk = useTranslations('brand.ruleKind');
  const errText = useErrorText();
  const router = useRouter();
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [busy, setBusy] = useState<string | null>(null);
  const [, start] = useTransition();
  const [deadline, setDeadline] = useState(() => toWibInput(submitDeadline));
  const [ruleId, setRuleId] = useState(rules[0]?.id ?? '');
  const [values, setValues] = useState<Record<string, string>>({});
  const [topup, setTopup] = useState<Record<string, string>>({});
  const running = RUNNING.includes(status);
  const rule = rules.find((r) => r.id === ruleId);
  const tiers = (Array.isArray(rule?.params.tiers) ? rule.params.tiers : []) as Record<string, unknown>[];

  const run = (key: string, input: ControlAction, done?: () => void) =>
    new Promise<void>((resolve) => {
      setBusy(key);
      start(async () => {
        const res = await controlCampaign(orgId, campaignId, input);
        setBusy(null);
        resolve();
        if (!res.ok) {
          toast.error(errText(res.error));
          return;
        }
        toast.success(t(`done.${input.action}`));
        done?.();
      });
    });

  if (!canControl && !canFund) return <Alert tone="info">{t('readOnly')}</Alert>;

  const ruleValue = (r: ControlRule) => {
    const p = r.params;
    if (r.kind === 'per_1k_views') return t('valueRate', { rate: formatNumber(num(p.rate), locale), unit: r.unitLabel });
    if (r.kind === 'flat_per_post') return t('valueAmount', { amount: formatNumber(num(p.amount), locale), unit: r.unitLabel });
    if (r.kind === 'milestone_bonus')
      return t('valueMilestone', { amount: formatNumber(num(p.amount), locale), unit: r.unitLabel, views: formatNumber(num(p.threshold), locale) });
    return t('valueTiers', { count: tiers.length });
  };

  const newParams = (): Record<string, unknown> | null => {
    if (!rule) return null;
    const v = (k: string) => num(values[k]);
    if (rule.kind === 'per_1k_views') return v('rate') > 0 ? { rate: v('rate') } : null;
    if (rule.kind === 'flat_per_post') return v('amount') > 0 ? { amount: v('amount') } : null;
    if (rule.kind === 'milestone_bonus') return v('amount') > 0 ? { threshold: num(rule.params.threshold), amount: v('amount') } : null;
    const next: Tier[] = tiers.map((x, i) => ({
      from: num(x.from),
      to: x.to == null ? null : num(x.to),
      rate: Number.isFinite(v(`tier${i}`)) && v(`tier${i}`) > 0 ? v(`tier${i}`) : num(x.rate),
    }));
    return { tiers: next };
  };

  const topupItems = pools.flatMap((p) => (num(topup[p.poolId]) > 0 ? [{ pool_id: p.poolId, amount: num(topup[p.poolId]) }] : []));

  return (
    <div className="grid gap-4 lg:grid-cols-2">
      {canControl ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('statusTitle')}</CardTitle>
            {t.has(`statusHint.${status}`) ? <CardDescription>{t(`statusHint.${status}`)}</CardDescription> : null}
          </CardHeader>
          <CardContent className="flex flex-wrap gap-2">
            {status === 'live' ? (
              <Button variant="secondary" iconLeft="pause" loading={busy === 'pause'} onClick={() => run('pause', { action: 'pause' })}>
                {t('pause')}
              </Button>
            ) : null}
            {status === 'paused' ? (
              <Button iconLeft="play_arrow" loading={busy === 'resume'} onClick={() => run('resume', { action: 'resume' })}>
                {t('resume')}
              </Button>
            ) : null}
            {['draft', 'in_review', 'scheduled', 'live', 'paused'].includes(status) ? (
              <ConfirmDialog
                trigger={<Button variant="danger" iconLeft="block">{t('endEarly')}</Button>}
                title={t('endTitle')}
                description={['live', 'paused'].includes(status) ? t('endBodyRunning') : t('endBodyCancel')}
                confirmLabel={t('endConfirm')}
                cancelLabel={t('cancel')}
                tone="danger"
                confirmText={title.slice(0, 40) || undefined}
                confirmTextLabel={t('typeTitle', { title: title.slice(0, 40) })}
                loading={busy === 'end_early'}
                onConfirm={() => run('end_early', { action: 'end_early' })}
              />
            ) : (
              <p className="text-body-s text-muted">{t('noStatusActions')}</p>
            )}
          </CardContent>
        </Card>
      ) : null}

      {canControl && running ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('extendTitle')}</CardTitle>
            <CardDescription>
              {submitDeadline ? t('currentDeadline', { date: formatDateTime(submitDeadline, locale) }) : t('extendHint')}
            </CardDescription>
          </CardHeader>
          <CardContent>
            <form
              className="flex flex-col gap-3 sm:flex-row sm:items-end"
              onSubmit={(e) => {
                e.preventDefault();
                const iso = fromWibInput(deadline);
                if (!iso) return toast.error(t('deadlineInvalid'));
                void run('extend', { action: 'extend', submit_deadline: iso });
              }}
            >
              <Field label={t('newDeadline')} helper={t('wib')} className="flex-1">
                <Input type="datetime-local" value={deadline} min={toWibInput(submitDeadline)} onChange={(e) => setDeadline(e.target.value)} required />
              </Field>
              <Button type="submit" loading={busy === 'extend'} iconLeft="event">{t('extend')}</Button>
            </form>
          </CardContent>
        </Card>
      ) : null}

      {canControl && running && rules.length ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('raiseTitle')}</CardTitle>
            <CardDescription>{t('raiseHint')}</CardDescription>
          </CardHeader>
          <CardContent>
            <form
              className="flex flex-col gap-3"
              onSubmit={(e) => {
                e.preventDefault();
                const params = newParams();
                if (!rule || !params) return toast.error(t('rateInvalid'));
                void run('raise_rate', { action: 'raise_rate', rule_id: rule.id, params }, () => setValues({}));
              }}
            >
              <Field label={t('rule')}>
                <Select
                  value={ruleId}
                  onValueChange={(v) => {
                    setRuleId(v);
                    setValues({});
                  }}
                  options={rules.map((r) => ({
                    value: r.id,
                    label: `${r.code} · ${tk(r.kind)} · ${r.platform ? platformLabel(r.platform as Platform) : t('allPlatforms')}`,
                    description: ruleValue(r),
                  }))}
                />
              </Field>
              {rule && rule.kind !== 'tiered_cpm' ? (
                <Field
                  label={rule.kind === 'per_1k_views' ? t('newRate', { unit: rule.unitLabel }) : t('newAmount', { unit: rule.unitLabel })}
                  helper={t('current', { value: ruleValue(rule) })}
                >
                  <Input
                    type="number"
                    inputMode="decimal"
                    min={0}
                    step="any"
                    value={values[rule.kind === 'per_1k_views' ? 'rate' : 'amount'] ?? ''}
                    onChange={(e) => setValues({ [rule.kind === 'per_1k_views' ? 'rate' : 'amount']: e.target.value })}
                    required
                  />
                </Field>
              ) : null}
              {rule?.kind === 'tiered_cpm'
                ? tiers.map((x, i) => (
                    <Field
                      key={i}
                      label={t('tierLabel', { from: formatNumber(num(x.from), locale), to: x.to == null ? '∞' : formatNumber(num(x.to), locale) })}
                      helper={t('current', { value: formatNumber(num(x.rate), locale) })}
                    >
                      <Input
                        type="number"
                        inputMode="decimal"
                        min={num(x.rate)}
                        step="any"
                        value={values[`tier${i}`] ?? ''}
                        onChange={(e) => setValues((cur) => ({ ...cur, [`tier${i}`]: e.target.value }))}
                      />
                    </Field>
                  ))
                : null}
              <Button type="submit" loading={busy === 'raise_rate'} iconLeft="trending_up" className="self-start">
                {t('raise')}
              </Button>
            </form>
          </CardContent>
        </Card>
      ) : null}

      {canFund && running && pools.length ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('topupTitle')}</CardTitle>
            <CardDescription>{t('topupHint')}</CardDescription>
          </CardHeader>
          <CardContent>
            <form
              className="flex flex-col gap-3"
              onSubmit={(e) => {
                e.preventDefault();
                if (!topupItems.length) return toast.error(t('topupEmpty'));
                void run('topup', { action: 'topup', pools: topupItems }, () => {
                  setTopup({});
                  router.push(`/${orgId}/billing`);
                });
              }}
            >
              {pools.map((p) => (
                <Field key={p.poolId} label={t('topupPool', { code: p.code })} optional>
                  <Input
                    type="number"
                    inputMode="decimal"
                    min={0}
                    step={p.decimals ? 1 / 10 ** p.decimals : 1}
                    prefix={p.code === 'IDR' ? 'Rp' : undefined}
                    suffix={p.code === 'IDR' ? undefined : p.unitLabel}
                    value={topup[p.poolId] ?? ''}
                    onChange={(e) => setTopup((cur) => ({ ...cur, [p.poolId]: e.target.value }))}
                  />
                </Field>
              ))}
              <div className="flex flex-wrap items-center gap-3">
                <Button type="submit" variant="ink" loading={busy === 'topup'} iconLeft="receipt_long">{t('topup')}</Button>
                <Link href={`/${orgId}/billing`} className="text-body-s font-semibold text-link focus-ring rounded-[4px]">{t('toBilling')}</Link>
              </div>
            </form>
          </CardContent>
        </Card>
      ) : null}
    </div>
  );
}
