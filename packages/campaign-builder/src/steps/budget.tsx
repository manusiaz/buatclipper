'use client';

import { Alert, Card, Switch, platformLabel } from '@clipper/ui';
import { capInViews, costSummary } from '../cost';
import { idr, num, units } from '../i18n';
import { rewardTypeById, ruleRatePer1k } from '../model';
import { Lock, NumberField, Section } from '../parts';
import type { Platform } from '../types';
import type { StepProps } from './shared';

export function BudgetStep({ draft, update, ctx, locked, t, locale, errorOf }: StepProps) {
  const summary = costSummary(draft, ctx);
  const setPool = (key: string, patch: { total?: number | null; max_per_clip?: number | null }) =>
    update((d) => ({ ...d, pools: d.pools.map((p) => (p.key === key ? { ...p, ...patch } : p)) }));

  return (
    <Lock disabled={locked}>
      <Section title={t('budget.section')} description={t('stepHints.budget')}>
        {errorOf('pools') ? <Alert tone="danger" title={errorOf('pools')} /> : null}
        {draft.pools.length === 0 ? <p className="text-body-s text-muted">{t('rewards.noPools')}</p> : null}
        <ol className="flex flex-col gap-4">
          {draft.pools.map((pool, i) => {
            const rt = rewardTypeById(ctx, pool.reward_type_id);
            const cost = summary.perPool[i];
            const isIdr = !rt || rt.code === 'IDR';
            const decimals = rt?.decimals ?? 0;
            const rates = draft.rules.filter((r) => r.pool === pool.key).map(ruleRatePer1k).filter((r): r is number => r != null && r > 0);
            const capViews = capInViews(pool.max_per_clip, rates.length ? Math.max(...rates) : null);
            const est = cost?.est;
            const byPlatform = est ? (Object.entries(est.byPlatform) as [Platform, number][]) : [];
            return (
              <Card as="li" key={pool.key} variant="outline" padding="md" className="flex flex-col gap-4">
                <h4 className="text-h6">{rt ? `${rt.name} (${rt.unit_label})` : t('rewards.pool', { n: i + 1 })}</h4>
                <div className="grid gap-4 sm:grid-cols-2">
                  <NumberField
                    label={t('budget.poolTotal')}
                    value={pool.total}
                    onChange={(total) => setPool(pool.key, { total })}
                    locale={locale}
                    decimals={decimals}
                    prefix={isIdr ? 'Rp' : undefined}
                    suffix={isIdr ? undefined : rt?.unit_label}
                    required
                    error={errorOf(`pools.${i}.total`)}
                    helper={!isIdr && cost && cost.total > 0 ? t('budget.poolTotalIdr', { idr: idr(cost.budgetIdr, locale) }) : t('budget.poolTotalHelper')}
                  />
                  <NumberField
                    label={t('budget.maxPerClip')}
                    value={pool.max_per_clip}
                    onChange={(max_per_clip) => setPool(pool.key, { max_per_clip })}
                    locale={locale}
                    decimals={decimals}
                    prefix={isIdr ? 'Rp' : undefined}
                    suffix={isIdr ? undefined : rt?.unit_label}
                    required
                    error={errorOf(`pools.${i}.max_per_clip`)}
                    helper={capViews != null ? t('budget.capViews', { views: num(capViews, locale) }) : t('budget.maxPerClipHelper')}
                  />
                </div>
                <div className="flex flex-col gap-1 rounded-card-sm bg-primary-soft px-3.5 py-3 text-primary-soft-fg">
                  {est ? (
                    <>
                      <p className="text-sm font-bold tnum">
                        {est.min === est.max
                          ? t('budget.estViews', { views: num(est.max, locale) })
                          : t('budget.estViewsRange', { min: num(est.min, locale), max: num(est.max, locale) })}
                      </p>
                      {est.min !== est.max ? (
                        <p className="text-caption">
                          {byPlatform.map(([p, v]) => `${platformLabel(p)} ${num(v, locale)}`).join(' · ')}
                        </p>
                      ) : null}
                      <p className="text-caption">{t('budget.estNote')}</p>
                    </>
                  ) : (
                    <p className="text-caption">{t('budget.estNone')}</p>
                  )}
                </div>
                {cost && cost.total > 0 && rt ? (
                  <p className="text-caption text-muted">{t('budget.poolSummary', { total: units(cost.total, rt, locale), idr: idr(cost.budgetIdr, locale) })}</p>
                ) : null}
              </Card>
            );
          })}
        </ol>
        <div className="flex items-center justify-between gap-3 rounded-card-sm border border-border px-4 py-3">
          <span className="text-label text-ink">{t('budget.totalBudget')}</span>
          <span className="text-h6 tnum">{idr(summary.budgetIdr, locale)}</span>
        </div>
      </Section>

      <Section title={t('budget.limits')} description={t('budget.limitsHint')}>
        <div className="grid gap-4 sm:grid-cols-2">
          <NumberField
            label={t('budget.minViews')}
            value={draft.min_views}
            onChange={(min_views) => update((d) => ({ ...d, min_views }))}
            locale={locale}
            suffix={t('common.views')}
            required
            helper={t('budget.minViewsHelper')}
            error={errorOf('min_views')}
          />
          <NumberField
            label={t('budget.maxClips')}
            value={draft.max_clips_per_clipper}
            onChange={(max_clips_per_clipper) => update((d) => ({ ...d, max_clips_per_clipper }))}
            locale={locale}
            suffix={t('common.clips')}
            required
            helper={t('budget.maxClipsHelper')}
            error={errorOf('max_clips_per_clipper')}
          />
          <NumberField
            label={t('budget.quota')}
            value={draft.clipper_quota}
            onChange={(clipper_quota) => update((d) => ({ ...d, clipper_quota }))}
            locale={locale}
            suffix={t('common.clippers')}
            optional={t('common.optional')}
            placeholder={t('budget.quotaPlaceholder')}
            helper={t('budget.quotaHelper')}
            error={errorOf('clipper_quota')}
          />
        </div>
        <Switch
          label={t('budget.reuse')}
          description={t('budget.reuseHint')}
          checked={draft.allow_video_reuse}
          onCheckedChange={(allow_video_reuse) => update((d) => ({ ...d, allow_video_reuse }))}
        />
      </Section>
    </Lock>
  );
}
