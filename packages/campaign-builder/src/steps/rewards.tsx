'use client';

import { Alert, Badge, Button, Card, Field, IconButton, Select, platformLabel } from '@clipper/ui';
import { EXAMPLE_VIEWS, RULE_KINDS } from '../constants';
import { idr, num, units, type Locale, type Translate } from '../i18n';
import { earningForViews, emptyParams, newPool, newRule, removePool, rewardTypeById, usableRewardTypes } from '../model';
import { Lock, NumberField, Section } from '../parts';
import type { CampaignDraft, RewardTypeOption, RuleDraft, RuleKind, TierDraft } from '../types';
import type { StepProps } from './shared';

function unitAffixes(rt: RewardTypeOption | undefined) {
  const isIdr = !rt || rt.code === 'IDR';
  return {
    prefix: isIdr ? 'Rp' : undefined,
    unit: isIdr ? '' : rt.unit_label,
    decimals: isIdr ? Math.max(rt?.decimals ?? 0, 0) : Math.max(rt.decimals, 2),
  };
}

function TiersEditor({
  tiers,
  onChange,
  rt,
  t,
  locale,
  errorOf,
  base,
}: {
  tiers: TierDraft[];
  onChange: (tiers: TierDraft[]) => void;
  rt: RewardTypeOption | undefined;
  t: Translate;
  locale: Locale;
  errorOf: StepProps['errorOf'];
  base: string;
}) {
  const a = unitAffixes(rt);
  const sync = (list: TierDraft[]) => list.map((tier, i) => (i === 0 ? { ...tier, from: 0 } : { ...tier, from: list[i - 1]!.to }));
  const set = (i: number, patch: Partial<TierDraft>) => onChange(sync(tiers.map((tier, j) => (j === i ? { ...tier, ...patch } : tier))));
  const last = tiers[tiers.length - 1];
  return (
    <div className="flex flex-col gap-3">
      <ol className="flex flex-col gap-3">
        {tiers.map((tier, i) => (
          <li key={i} className="grid grid-cols-2 items-start gap-3 rounded-card-sm border border-border bg-surface-2 p-3 sm:grid-cols-[1fr_1fr_1fr_auto]">
            <div className="flex flex-col gap-1.5">
              <span className="text-label text-ink">{t('rewards.tierFrom')}</span>
              <span className="flex h-12 items-center rounded-control bg-subtle px-3.5 text-base font-semibold text-text-2 tnum">
                {tier.from == null ? '—' : num(tier.from, locale)}
              </span>
              {errorOf(`${base}.${i}.from`) ? <span className="text-caption font-medium text-danger-fg">{errorOf(`${base}.${i}.from`)}</span> : null}
            </div>
            <NumberField
              label={t('rewards.tierTo')}
              value={tier.to}
              onChange={(to) => set(i, { to })}
              locale={locale}
              placeholder={i === tiers.length - 1 ? t('rewards.tierOpen') : undefined}
              suffix={t('common.views')}
              error={errorOf(`${base}.${i}.to`)}
            />
            <NumberField
              label={t('rewards.tierRate')}
              value={tier.rate}
              onChange={(rate) => set(i, { rate })}
              locale={locale}
              decimals={a.decimals}
              prefix={a.prefix}
              suffix={a.unit ? `${a.unit} / 1K` : '/ 1K'}
              error={errorOf(`${base}.${i}.rate`)}
              className="col-span-2 sm:col-span-1"
            />
            <div className="col-span-2 flex justify-end sm:col-span-1 sm:pt-7">
              <IconButton
                variant="ghost"
                size="md"
                icon="delete"
                label={t('rewards.removeTier', { n: i + 1 })}
                disabled={tiers.length === 1}
                onClick={() => onChange(sync(tiers.filter((_, j) => j !== i)))}
              />
            </div>
          </li>
        ))}
      </ol>
      <div className="flex flex-wrap items-center gap-2">
        <Button
          variant="tertiary"
          size="sm"
          iconLeft="add"
          disabled={!last || last.to == null}
          onClick={() => onChange(sync([...tiers, { from: last?.to ?? null, to: null, rate: null }]))}
        >
          {t('rewards.addTier')}
        </Button>
        {last && last.to == null ? <span className="text-caption text-muted">{t('rewards.addTierHint')}</span> : null}
      </div>
    </div>
  );
}

function RuleEditor({ rule, index, draft, update, rt, t, locale, errorOf }: { rule: RuleDraft; index: number; draft: CampaignDraft; update: StepProps['update']; rt: RewardTypeOption | undefined; t: Translate; locale: Locale; errorOf: StepProps['errorOf'] }) {
  const a = unitAffixes(rt);
  const base = `rules.${index}.params`;
  const setRule = (fn: (r: RuleDraft) => RuleDraft) => update((d) => ({ ...d, rules: d.rules.map((r) => (r.key === rule.key ? fn(r) : r)) }));
  const setParams = (patch: RuleDraft['params']) => setRule((r) => ({ ...r, params: { ...r.params, ...patch } }));
  const changeKind = (kind: RuleKind) =>
    setRule((r) => {
      const params = emptyParams(kind);
      const rate = r.kind === 'tiered_cpm' ? (r.params.tiers?.[0]?.rate ?? null) : (r.params.rate ?? null);
      if (kind === 'per_1k_views') params.rate = rate;
      if (kind === 'tiered_cpm') params.tiers = [{ from: 0, to: null, rate }];
      if ((kind === 'flat_per_post' || kind === 'milestone_bonus') && r.params.amount != null) params.amount = r.params.amount;
      return { ...r, kind, params };
    });
  const ex = earningForViews(rule, EXAMPLE_VIEWS);
  const platformInvalid = errorOf(`rules.${index}.platform`);

  return (
    <li className="flex flex-col gap-4 rounded-card-sm border border-border bg-surface p-3 sm:p-4">
      <div className="grid gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
        <Field label={t('rewards.ruleKind')}>
          <Select
            value={rule.kind}
            onValueChange={(v) => changeKind(v as RuleKind)}
            options={RULE_KINDS.map((k) => ({ value: k, label: t(`kinds.${k}`), description: t(`kindHints.${k}`) }))}
          />
        </Field>
        <Field label={t('rewards.rulePlatform')} error={platformInvalid}>
          <Select
            value={rule.platform ?? 'all'}
            onValueChange={(v) => setRule((r) => ({ ...r, platform: v === 'all' ? null : (v as RuleDraft['platform']) }))}
            options={[
              { value: 'all', label: t('rewards.allPlatforms') },
              ...draft.platforms.map((p) => ({ value: p, label: platformLabel(p) })),
              ...(rule.platform && !draft.platforms.includes(rule.platform) ? [{ value: rule.platform, label: platformLabel(rule.platform), disabled: true }] : []),
            ]}
          />
        </Field>
        <div className="flex justify-end">
          <IconButton
            variant="ghost"
            icon="delete"
            label={t('rewards.removeRule')}
            onClick={() => update((d) => ({ ...d, rules: d.rules.filter((r) => r.key !== rule.key) }))}
          />
        </div>
      </div>

      {rule.kind === 'per_1k_views' ? (
        <NumberField
          label={t('rewards.rate')}
          value={rule.params.rate ?? null}
          onChange={(rate) => setParams({ rate })}
          locale={locale}
          decimals={a.decimals}
          prefix={a.prefix}
          suffix={a.unit ? `${a.unit} / 1K` : '/ 1K'}
          required
          error={errorOf(`${base}.rate`)}
          className="sm:max-w-xs"
        />
      ) : rule.kind === 'flat_per_post' ? (
        <NumberField
          label={t('rewards.amountPerPost')}
          value={rule.params.amount ?? null}
          onChange={(amount) => setParams({ amount })}
          locale={locale}
          decimals={a.decimals}
          prefix={a.prefix}
          suffix={a.unit || undefined}
          required
          error={errorOf(`${base}.amount`)}
          className="sm:max-w-xs"
        />
      ) : rule.kind === 'milestone_bonus' ? (
        <div className="grid gap-3 sm:grid-cols-2">
          <NumberField
            label={t('rewards.threshold')}
            value={rule.params.threshold ?? null}
            onChange={(threshold) => setParams({ threshold })}
            locale={locale}
            suffix={t('common.views')}
            required
            error={errorOf(`${base}.threshold`)}
          />
          <NumberField
            label={t('rewards.bonus')}
            value={rule.params.amount ?? null}
            onChange={(amount) => setParams({ amount })}
            locale={locale}
            decimals={a.decimals}
            prefix={a.prefix}
            suffix={a.unit || undefined}
            required
            error={errorOf(`${base}.amount`)}
          />
        </div>
      ) : (
        <div className="flex flex-col gap-2">
          <span className="text-label text-ink">{t('rewards.tiers')}</span>
          {errorOf(`${base}.tiers`) ? <span className="text-caption font-medium text-danger-fg">{errorOf(`${base}.tiers`)}</span> : null}
          <TiersEditor
            tiers={rule.params.tiers ?? []}
            onChange={(tiers) => setParams({ tiers })}
            rt={rt}
            t={t}
            locale={locale}
            errorOf={errorOf}
            base={`${base}.tiers`}
          />
        </div>
      )}

      <p className="text-caption text-muted">
        {t(`kindHints.${rule.kind}`)}
        {ex != null && ex > 0 && (rule.kind === 'per_1k_views' || rule.kind === 'tiered_cpm')
          ? ` · ${t('platforms.example', { views: num(EXAMPLE_VIEWS, locale), amount: units(ex, rt, locale) })}`
          : ''}
      </p>
    </li>
  );
}

export function RewardsStep({ draft, update, ctx, locked, t, locale, errorOf }: StepProps) {
  const usable = usableRewardTypes(ctx);
  const used = new Set(draft.pools.map((p) => p.reward_type_id));
  const nextType = usable.find((rt) => !used.has(rt.id));

  return (
    <Lock disabled={locked}>
      <Section title={t('rewards.section')} description={t('stepHints.rewards')}>
        {errorOf('pools') ? (
          <Alert tone="danger" title={errorOf('pools')} />
        ) : null}
        {errorOf('rules') ? <Alert tone="danger" title={errorOf('rules')} /> : null}
        {draft.pools.length === 0 ? <p className="text-body-s text-muted">{t('rewards.noPools')}</p> : null}
        <ol className="flex flex-col gap-4">
          {draft.pools.map((pool, i) => {
            const rt = rewardTypeById(ctx, pool.reward_type_id);
            const poolRules = draft.rules.map((r, idx) => ({ r, idx })).filter(({ r }) => r.pool === pool.key);
            return (
              <Card as="li" key={pool.key} variant="outline" padding="md" className="flex flex-col gap-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="flex flex-col gap-1">
                    <h4 className="flex flex-wrap items-center gap-2 text-h6">
                      {t('rewards.pool', { n: i + 1 })}
                      {i === 0 ? (
                        <Badge tone="primary" size="sm">
                          {t('rewards.mainPool')}
                        </Badge>
                      ) : null}
                    </h4>
                    {rt ? <p className="text-caption text-muted">{t('rewards.rewardTypeHint', { unit: rt.unit_label, idr: idr(rt.idr_value_per_unit, locale) })}</p> : null}
                  </div>
                  <IconButton variant="ghost" icon="delete" label={t('rewards.removePool', { n: i + 1 })} onClick={() => update((d) => removePool(d, pool.key))} />
                </div>
                <Field label={t('rewards.rewardType')} required error={errorOf(`pools.${i}.reward_type_id`) ?? errorOf(`pools.${i}`)}>
                  <Select
                    value={pool.reward_type_id || undefined}
                    placeholder={t('rewards.rewardTypePlaceholder')}
                    onValueChange={(v) => update((d) => ({ ...d, pools: d.pools.map((p) => (p.key === pool.key ? { ...p, reward_type_id: v } : p)) }))}
                    options={[
                      ...usable.map((o) => ({
                        value: o.id,
                        label: `${o.name} (${o.unit_label})`,
                        description: o.owner_org_id ? t('rewards.ownType') : undefined,
                        disabled: used.has(o.id) && o.id !== pool.reward_type_id,
                      })),
                      ...(rt && !usable.includes(rt) ? [{ value: rt.id, label: `${rt.name} (${rt.unit_label})`, disabled: true }] : []),
                    ]}
                  />
                </Field>
                <div className="flex flex-col gap-3">
                  <span className="text-label text-ink">{t('rewards.rules')}</span>
                  {poolRules.length === 0 ? <p className="text-body-s text-muted">{t('rewards.noRules')}</p> : null}
                  <ul className="flex flex-col gap-3">
                    {poolRules.map(({ r, idx }) => (
                      <RuleEditor key={r.key} rule={r} index={idx} draft={draft} update={update} rt={rt} t={t} locale={locale} errorOf={errorOf} />
                    ))}
                  </ul>
                  <div>
                    <Button variant="tertiary" size="md" iconLeft="add" onClick={() => update((d) => ({ ...d, rules: [...d.rules, newRule(pool.key)] }))}>
                      {t('rewards.addRule')}
                    </Button>
                  </div>
                </div>
              </Card>
            );
          })}
        </ol>
        <div className="flex flex-col items-start gap-1.5">
          <Button
            variant="secondary"
            iconLeft="add_circle"
            disabled={!nextType}
            onClick={() =>
              update((d) => {
                if (!nextType) return d;
                const pool = newPool(nextType.id);
                return { ...d, pools: [...d.pools, pool], rules: [...d.rules, newRule(pool.key)] };
              })
            }
          >
            {t('rewards.addPool')}
          </Button>
          <span className="text-caption text-muted">{nextType ? t('rewards.addPoolHint') : t('rewards.allTypesUsed')}</span>
        </div>
      </Section>
    </Lock>
  );
}
