'use client';

import type { ReactNode } from 'react';
import { Alert, Badge, Button, Card, Field, Icon, Select, formatDateTime, platformLabel } from '@clipper/ui';
import type { CostSummary } from '../cost';
import { idr, num, units, type Locale, type Translate } from '../i18n';
import { rewardTypeById } from '../model';
import { NumberField } from '../parts';
import type { DraftIssue } from '../schema';
import type { BuilderContext, CampaignDraft, FeeOverride, RewardTypeOption, RuleDraft, StepId } from '../types';
import type { StepProps } from './shared';

export function describeRule(rule: RuleDraft, rt: RewardTypeOption | undefined, t: Translate, locale: Locale): string {
  const u = (n: number | null | undefined) => (n == null ? '—' : units(n, rt, locale));
  const p = rule.params;
  const where = rule.platform ? platformLabel(rule.platform) : t('rewards.allPlatforms');
  let body: string;
  switch (rule.kind) {
    case 'per_1k_views':
      body = t('summary.rulePer1k', { amount: u(p.rate) });
      break;
    case 'flat_per_post':
      body = t('summary.ruleFlat', { amount: u(p.amount) });
      break;
    case 'milestone_bonus':
      body = t('summary.ruleMilestone', { amount: u(p.amount), views: p.threshold == null ? '—' : num(p.threshold, locale) });
      break;
    case 'tiered_cpm':
      body = (p.tiers ?? [])
        .map((tier) =>
          tier.to == null
            ? t('summary.tierOpen', { from: num(tier.from ?? 0, locale), amount: u(tier.rate) })
            : t('summary.tierRange', { from: num(tier.from ?? 0, locale), to: num(tier.to, locale), amount: u(tier.rate) }),
        )
        .join(' · ');
      break;
  }
  return `${where}: ${body}`;
}

function Row({ label, children }: { label: ReactNode; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5 py-2 sm:flex-row sm:gap-4">
      <dt className="text-caption font-semibold text-muted sm:w-44 sm:shrink-0 sm:pt-0.5">{label}</dt>
      <dd className="min-w-0 text-body-s break-words text-ink">{children}</dd>
    </div>
  );
}

function Block({ title, step, goTo, t, children }: { title: string; step: StepId; goTo: (s: StepId) => void; t: Translate; children: ReactNode }) {
  return (
    <Card variant="outline" padding="md" as="section">
      <div className="mb-1 flex items-center justify-between gap-3">
        <h3 className="text-h6">{title}</h3>
        <Button variant="ghost" size="sm" iconLeft="edit" onClick={() => goTo(step)} aria-label={`${t('nav.edit')}: ${title}`}>
          {t('nav.edit')}
        </Button>
      </div>
      <dl className="divide-y divide-border">{children}</dl>
    </Card>
  );
}

function feeValue(fee: FeeOverride): string {
  if (fee.mode === 'keep') return 'keep';
  if (fee.mode === 'clear') return 'clear';
  return fee.source_id ? `rule:${fee.source_id}` : 'custom';
}

function FeeOverrideControl({ draft, update, ctx, t, locale, effectiveFee, errorOf }: { draft: CampaignDraft; update: StepProps['update']; ctx: BuilderContext; t: Translate; locale: Locale; effectiveFee: BuilderContext['fee']; errorOf: StepProps['errorOf'] }) {
  const rules = ctx.feeRules ?? [];
  const scopeLabel = (scope: string) => (['global', 'org', 'campaign'].includes(scope) ? t(`summary.feeScope.${scope}`) : scope);
  const onChange = (v: string) =>
    update((d) => {
      if (v === 'keep') return { ...d, fee: { mode: 'keep' } };
      if (v === 'clear') return { ...d, fee: { mode: 'clear' } };
      if (v === 'custom') {
        const cur = d.fee.mode === 'set' ? d.fee : { mgmt_fee_pct: effectiveFee.mgmt_fee_pct, admin_fee_pct: effectiveFee.admin_fee_pct };
        return { ...d, fee: { mode: 'set', source_id: null, mgmt_fee_pct: cur.mgmt_fee_pct, admin_fee_pct: cur.admin_fee_pct } };
      }
      const rule = rules.find((r) => `rule:${r.id}` === v);
      return rule ? { ...d, fee: { mode: 'set', source_id: rule.id, mgmt_fee_pct: rule.mgmt_fee_pct, admin_fee_pct: rule.admin_fee_pct } } : d;
    });
  const value = feeValue(draft.fee);
  return (
    <div className="flex flex-col gap-3 rounded-card-sm border border-dashed border-border-strong p-3">
      <Field label={t('summary.feeOverride')} helper={t('summary.feeOverrideHint')} error={errorOf('fee')}>
        <Select
          value={value}
          onValueChange={onChange}
          options={[
            { value: 'keep', label: t('summary.feeKeep', { mgmt: effectiveFee.mgmt_fee_pct, admin: effectiveFee.admin_fee_pct }) },
            ...rules.map((r) => ({
              value: `rule:${r.id}`,
              label: t('summary.feeRuleOption', { scope: scopeLabel(r.scope), mgmt: r.mgmt_fee_pct, admin: r.admin_fee_pct }),
            })),
            { value: 'custom', label: t('summary.feeCustom') },
            { value: 'clear', label: t('summary.feeClear') },
          ]}
        />
      </Field>
      {draft.fee.mode === 'set' && !draft.fee.source_id ? (
        <div className="grid grid-cols-2 gap-3">
          <NumberField
            label={t('summary.mgmtPct')}
            value={draft.fee.mgmt_fee_pct}
            decimals={2}
            locale={locale}
            suffix="%"
            error={errorOf('fee.mgmt_fee_pct')}
            onChange={(v) => update((d) => (d.fee.mode === 'set' ? { ...d, fee: { ...d.fee, mgmt_fee_pct: v ?? 0 } } : d))}
          />
          <NumberField
            label={t('summary.adminPct')}
            value={draft.fee.admin_fee_pct}
            decimals={2}
            locale={locale}
            suffix="%"
            error={errorOf('fee.admin_fee_pct')}
            onChange={(v) => update((d) => (d.fee.mode === 'set' ? { ...d, fee: { ...d.fee, admin_fee_pct: v ?? 0 } } : d))}
          />
        </div>
      ) : null}
    </div>
  );
}

export interface SummaryProps extends StepProps {
  cost: CostSummary;
  issues: DraftIssue[];
  effectiveFee: BuilderContext['fee'];
  submit: ReactNode;
}

export function SummaryStep({ draft, update, ctx, locked, t, locale, errorOf, goTo, cost, issues, effectiveFee, submit }: SummaryProps) {
  const type = t(`types.${draft.type}`);
  const category = ctx.categories.find((c) => c.id === draft.category_id);
  const wib = (iso: string | null) => (iso ? `${formatDateTime(iso, locale)} WIB` : t('summary.notSet'));
  const list = (items: string[], prefix = '') => (items.length ? items.map((x) => `${prefix}${x}`).join(', ') : t('summary.none'));
  const stepsWithIssues = [...new Set(issues.map((i) => i.step))];

  return (
    <div className="flex flex-col gap-5">
      {issues.length > 0 && !locked ? (
        <Alert tone="warn" title={t('summary.issuesTitle')}>
          <ul className="mt-1 flex flex-col gap-1.5">
            {stepsWithIssues.map((step) => (
              <li key={step} className="flex flex-wrap items-center gap-x-2 gap-y-1">
                <span className="font-semibold text-ink">{t(`steps.${step}`)}:</span>
                <span>{[...new Set(issues.filter((i) => i.step === step).map((i) => t(i.message)))].join(' · ')}</span>
                {step !== 'summary' ? (
                  <Button variant="link" size="sm" onClick={() => goTo(step)}>
                    {t('summary.fixIssue')}
                  </Button>
                ) : null}
              </li>
            ))}
          </ul>
        </Alert>
      ) : null}

      <div className="grid gap-4 xl:grid-cols-2">
        <Block title={t('steps.basics')} step="basics" goTo={goTo} t={t}>
          <Row label={t('basics.title')}>{draft.title.trim() || t('summary.notSet')}</Row>
          <Row label={t('basics.type')}>{type}</Row>
          <Row label={t('basics.category')}>{category ? (locale === 'en' ? category.name_en : category.name_id) : t('summary.none')}</Row>
          <Row label={t('basics.cover')}>{draft.cover ? draft.cover.name : t('summary.none')}</Row>
        </Block>

        <Block title={t('steps.brief')} step="brief" goTo={goTo} t={t}>
          <Row label={t('brief.modeLegend')}>
            {draft.service_mode === 'managed' ? (
              <Badge tone="primary" icon="support_agent">
                {t('brief.modeManaged')}
              </Badge>
            ) : (
              t('brief.modeSelf')
            )}
          </Row>
          <Row label={t('brief.text')}>{draft.brief.trim() ? t('summary.briefChars', { n: [...draft.brief.trim()].length }) : t('summary.notSet')}</Row>
          <Row label={t('brief.hashtags')}>{list(draft.required_hashtags, '#')}</Row>
          <Row label={t('brief.mentions')}>{list(draft.required_mentions, '@')}</Row>
          <Row label={t('brief.links')}>{list(draft.required_links)}</Row>
          <Row label={t('summary.duration')}>
            {draft.min_duration_sec == null && draft.max_duration_sec == null
              ? t('summary.none')
              : t('summary.durationValue', { min: draft.min_duration_sec ?? '—', max: draft.max_duration_sec ?? '—' })}
          </Row>
          <Row label={t('brief.sponsored')}>{draft.sponsored_label ? t('summary.yes') : t('summary.no')}</Row>
          <Row label={t('brief.faq')}>{t('summary.count', { n: draft.faq.filter((f) => f.q.trim()).length })}</Row>
          <Row label={t('brief.assets')}>{t('summary.count', { n: draft.assets.length })}</Row>
        </Block>

        <Block title={t('steps.platforms')} step="platforms" goTo={goTo} t={t}>
          <Row label={t('platforms.legend')}>{draft.platforms.length ? draft.platforms.map(platformLabel).join(', ') : t('summary.notSet')}</Row>
        </Block>

        <Block title={t('steps.rewards')} step="rewards" goTo={goTo} t={t}>
          {draft.pools.length === 0 ? <Row label={t('rewards.section')}>{t('summary.notSet')}</Row> : null}
          {draft.pools.map((pool, i) => {
            const rt = rewardTypeById(ctx, pool.reward_type_id);
            const pc = cost.perPool[i];
            return (
              <Row key={pool.key} label={rt ? `${rt.name} (${rt.unit_label})` : t('rewards.pool', { n: i + 1 })}>
                <ul className="flex flex-col gap-0.5">
                  <li className="font-semibold tnum">
                    {pool.total != null && rt ? t('summary.poolTotal', { total: units(pool.total, rt, locale), idr: idr(pc?.budgetIdr ?? 0, locale) }) : t('summary.notSet')}
                  </li>
                  <li className="text-muted">{t('summary.poolCap', { cap: pool.max_per_clip != null ? units(pool.max_per_clip, rt, locale) : '—' })}</li>
                  {pc?.est ? (
                    <li className="text-muted">
                      {pc.est.min === pc.est.max
                        ? t('budget.estViews', { views: num(pc.est.max, locale) })
                        : t('budget.estViewsRange', { min: num(pc.est.min, locale), max: num(pc.est.max, locale) })}
                    </li>
                  ) : null}
                  {draft.rules
                    .filter((r) => r.pool === pool.key)
                    .map((r) => (
                      <li key={r.key} className="text-text-2">
                        {t(`kinds.${r.kind}`)} · {describeRule(r, rt, t, locale)}
                      </li>
                    ))}
                </ul>
              </Row>
            );
          })}
          <Row label={t('budget.minViews')}>{draft.min_views == null ? '—' : num(draft.min_views, locale)}</Row>
          <Row label={t('budget.maxClips')}>{draft.max_clips_per_clipper ?? '—'}</Row>
          <Row label={t('budget.quota')}>{draft.clipper_quota == null ? t('summary.unlimited') : num(draft.clipper_quota, locale)}</Row>
        </Block>

        <Block title={t('steps.eligibility')} step="eligibility" goTo={goTo} t={t}>
          <Row label={t('eligibility.minFollowers')}>{num(draft.min_followers ?? 0, locale)}</Row>
          <Row label={t('eligibility.accountAge')}>{t('summary.days', { n: draft.min_account_age_days ?? 0 })}</Row>
          <Row label={t('eligibility.trust')}>{draft.min_trust_score ?? 0}</Row>
          <Row label={t('eligibility.kyc')}>{draft.kyc_required ? t('summary.yes') : t('summary.no')}</Row>
          <Row label={t('eligibility.visibility')}>{t(`visibilities.${draft.visibility}`)}</Row>
        </Block>

        <Block title={t('steps.schedule')} step="schedule" goTo={goTo} t={t}>
          <Row label={t('schedule.startAt')}>{wib(draft.start_at)}</Row>
          <Row label={t('schedule.deadline')}>{wib(draft.submit_deadline)}</Row>
          <Row label={t('schedule.viewWindow')}>{t('summary.days', { n: draft.view_window_days ?? 0 })}</Row>
          <Row label={t('schedule.reviewMode')}>{t(`reviewModes.${draft.review_mode}`)}</Row>
        </Block>
      </div>

      <Card variant="raised" padding="lg" as="section" aria-labelledby="cb-cost-title">
        <h3 id="cb-cost-title" className="mb-3 flex items-center gap-2 text-h5">
          <Icon name="receipt_long" size={22} />
          {t('summary.cost')}
        </h3>
        <dl className="flex flex-col divide-y divide-border">
          <div className="flex items-baseline justify-between gap-3 py-2.5">
            <dt className="text-body-s text-text-2">{t('summary.budgetLine')}</dt>
            <dd className="font-semibold tnum">{idr(cost.budgetIdr, locale)}</dd>
          </div>
          {cost.nonCashIdr > 0 ? (
            <div className="flex items-baseline justify-between gap-3 py-2.5">
              <dt className="text-body-s text-text-2">{t('summary.nonCashLine')}</dt>
              <dd className="text-body-s text-muted tnum">{idr(cost.nonCashIdr, locale)}</dd>
            </div>
          ) : null}
          <div className="flex items-baseline justify-between gap-3 py-2.5">
            <dt className="text-body-s text-text-2">{t('summary.mgmtFee', { pct: cost.mgmtFeePct })}</dt>
            <dd className="font-semibold tnum">{idr(cost.mgmtFee, locale)}</dd>
          </div>
          <div className="flex items-baseline justify-between gap-3 py-2.5">
            <dt className="text-body-s text-text-2">{t('summary.adminFee', { pct: cost.adminFeePct })}</dt>
            <dd className="font-semibold tnum">{idr(cost.adminFee, locale)}</dd>
          </div>
          {draft.service_mode === 'managed' ? (
            <div className="flex items-baseline justify-between gap-3 py-2.5">
              <dt className="text-body-s text-text-2">{t('summary.serviceFee')}</dt>
              <dd className="font-semibold tnum">{idr(cost.serviceFee, locale)}</dd>
            </div>
          ) : null}
          <div className="flex items-baseline justify-between gap-3 py-2.5">
            <dt className="text-body-s text-text-2">{t('summary.tax', { pct: cost.taxPct })}</dt>
            <dd className="font-semibold tnum">{idr(cost.tax, locale)}</dd>
          </div>
          <div className="flex items-baseline justify-between gap-3 pt-3">
            <dt className="text-h6">{t('summary.total')}</dt>
            <dd className="text-numeric tnum">{idr(cost.total, locale)}</dd>
          </div>
        </dl>
        <p className="mt-3 text-caption text-muted">{draft.service_mode === 'managed' ? t('summary.totalNoteManaged') : t('summary.totalNote')}</p>
        {cost.perPool.some((p) => p.unknownRewardType) ? <p className="mt-1 text-caption text-warn-fg">{t('summary.unknownRewardType')}</p> : null}
        {ctx.mode === 'admin' && !locked ? (
          <div className="mt-4">
            <FeeOverrideControl draft={draft} update={update} ctx={ctx} t={t} locale={locale} effectiveFee={effectiveFee} errorOf={errorOf} />
          </div>
        ) : null}
      </Card>

      {submit}
    </div>
  );
}
