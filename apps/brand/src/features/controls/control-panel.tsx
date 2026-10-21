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
  formatIDR,
  formatNumber,
  platformLabel,
  toast,
  type Platform,
} from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { controlCampaign, type ControlAction } from './actions';

export interface ControlRule {
  id: string;
  /** Versi rule yang sama lintas raise_rate (lineage_id ?? id): pilihan tetap menunjuk rule pengganti. */
  lineage: string;
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
  canBilling,
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
  /** Invoice hanya terlihat owner/finance (RLS invoices); manajer tetap di halaman ini. */
  canBilling: boolean;
}) {
  const t = useTranslations('brand.controls');
  const tk = useTranslations('brand.ruleKind');
  const errText = useErrorText();
  const router = useRouter();
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [busy, setBusy] = useState<string | null>(null);
  const [, start] = useTransition();
  const [deadline, setDeadline] = useState(() => toWibInput(submitDeadline));
  const [lineage, setLineage] = useState(rules[0]?.lineage ?? '');
  const [values, setValues] = useState<Record<string, string>>({});
  const [topup, setTopup] = useState<Record<string, string>>({});
  const running = RUNNING.includes(status);
  const rule = rules.find((r) => r.lineage === lineage) ?? rules[0];
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

  const money = (r: ControlRule, v: unknown) =>
    r.code === 'IDR' ? formatIDR(num(v), { locale }) : `${formatNumber(num(v), locale, { maximumFractionDigits: 6 })} ${r.unitLabel}`;
  const ruleValue = (r: ControlRule) => {
    const p = r.params;
    if (r.kind === 'per_1k_views') return t('valueRate', { value: money(r, p.rate) });
    if (r.kind === 'flat_per_post') return t('valueAmount', { value: money(r, p.amount) });
    if (r.kind === 'milestone_bonus') return t('valueMilestone', { value: money(r, p.amount), views: formatNumber(num(p.threshold), locale) });
    return t('valueTiers', { count: Array.isArray(p.tiers) ? p.tiers.length : 0 });
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
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-2 [&>*]:min-w-0">
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
            {status === 'live' ? (
              <Button variant="secondary" iconLeft="campaign" loading={busy === 'notify'} onClick={() => run('notify', { action: 'notify_eligible' })}>
                {t('notifyEligible')}
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
              className="flex flex-col gap-3"
              onSubmit={(e) => {
                e.preventDefault();
                const iso = fromWibInput(deadline);
                if (!iso) return toast.error(t('deadlineInvalid'));
                void run('extend', { action: 'extend', submit_deadline: iso });
              }}
            >
              <Field label={t('newDeadline')} helper={t('wib')}>
                <Input type="datetime-local" value={deadline} min={toWibInput(submitDeadline)} onChange={(e) => setDeadline(e.target.value)} required />
              </Field>
              <Button type="submit" loading={busy === 'extend'} iconLeft="event" className="self-start">{t('extend')}</Button>
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
                  value={rule?.id ?? ''}
                  onValueChange={(v) => {
                    setLineage(rules.find((r) => r.id === v)?.lineage ?? '');
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
                      helper={t('current', { value: rule ? money(rule, x.rate) : '' })}
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
                  if (canBilling) router.push(`/${orgId}/billing`);
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
                {canBilling ? <Link href={`/${orgId}/billing`} className="text-body-s font-semibold text-link focus-ring rounded-[4px]">{t('toBilling')}</Link> : null}
              </div>
            </form>
          </CardContent>
        </Card>
      ) : null}
    </div>
  );
}
