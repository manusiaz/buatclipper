'use client';

import { Alert, Badge, Button, PlatformIcon, RadioGroup, platformLabel } from '@clipper/ui';
import { EXAMPLE_VIEWS, PLATFORMS } from '../constants';
import { units } from '../i18n';
import { basePool, baseRateMode, baseRules, earningForViews, newRule, rewardTypeById, setBaseRate, setBaseRateMode, togglePlatform } from '../model';
import { Lock, NumberField, Section, ToggleCard } from '../parts';
import type { Platform } from '../types';
import type { StepProps } from './shared';

export function PlatformsStep({ draft, update, ctx, locked, t, locale, errorOf, goTo }: StepProps) {
  const shown = PLATFORMS.filter((p) => ctx.platforms[p] || draft.platforms.includes(p));
  const pool = basePool(draft);
  const rt = rewardTypeById(ctx, pool?.reward_type_id);
  const mode = baseRateMode(draft);
  const rules = baseRules(draft);
  const ruleIndex = (key: string) => draft.rules.findIndex((r) => r.key === key);
  const decimals = Math.max(rt?.decimals ?? 0, rt?.code === 'IDR' ? 0 : 2);
  const prefix = rt?.code === 'IDR' || !rt ? 'Rp' : undefined;
  const suffix = rt && rt.code !== 'IDR' ? `${rt.unit_label} / 1K` : '/ 1K';

  const example = (rate: number | null | undefined) => {
    if (rate == null || !(rate > 0)) return null;
    const amount = earningForViews({ kind: 'per_1k_views', params: { rate } }, EXAMPLE_VIEWS) ?? 0;
    return t('platforms.example', { views: EXAMPLE_VIEWS.toLocaleString(locale === 'en' ? 'en-US' : 'id-ID'), amount: units(amount, rt, locale) });
  };

  const rateField = (platform: Platform | null) => {
    const rule = rules.find((r) => r.platform === platform);
    const idx = rule ? ruleIndex(rule.key) : -1;
    const ex = example(rule?.params.rate);
    return (
      <NumberField
        key={platform ?? 'all'}
        label={platform ? t('platforms.rateFor', { platform: platformLabel(platform) }) : t('platforms.rateAll')}
        value={rule?.params.rate ?? null}
        onChange={(rate) => update((d) => setBaseRate(d, platform, rate))}
        locale={locale}
        decimals={decimals}
        prefix={prefix}
        suffix={suffix}
        required
        helper={ex ?? t('platforms.rateHelper')}
        error={idx >= 0 ? errorOf(`rules.${idx}.params.rate`) : undefined}
      />
    );
  };

  return (
    <Lock disabled={locked}>
      <Section title={t('platforms.legend')} description={t('stepHints.platforms')}>
        <div className="grid gap-2.5 sm:grid-cols-2" role="group" aria-label={t('platforms.legend')}>
          {shown.map((p) => (
            <ToggleCard
              key={p}
              checked={draft.platforms.includes(p)}
              onChange={(on) => update((d) => togglePlatform(d, p, on))}
              description={ctx.platforms[p] ? undefined : t('platforms.disabled')}
            >
              <PlatformIcon platform={p} size={20} />
              {platformLabel(p)}
              {!ctx.platforms[p] ? (
                <Badge tone="warn" size="sm">
                  {t('platforms.disabledBadge')}
                </Badge>
              ) : null}
            </ToggleCard>
          ))}
        </div>
        {errorOf('platforms') ? (
          <p role="alert" className="text-caption font-medium text-danger-fg">
            {errorOf('platforms')}
          </p>
        ) : null}
      </Section>

      <Section
        title={t('platforms.rateTitle')}
        description={rt ? t('platforms.rateIntro', { reward: rt.name, unit: rt.unit_label }) : t('platforms.rateIntroNoPool')}
      >
        {!pool ? (
          <Alert tone="info" title={t('platforms.noPoolsTitle')} action={{ label: t('platforms.goRewards'), onClick: () => goTo('rewards') }}>
            {t('platforms.noPoolsBody')}
          </Alert>
        ) : mode === 'none' ? (
          <Alert tone="info" title={t('platforms.noneTitle')}>
            <div className="flex flex-col items-start gap-2">
              <span>{t('platforms.noneBody')}</span>
              <Button size="sm" variant="secondary" iconLeft="add" onClick={() => update((d) => ({ ...d, rules: [newRule(pool.key), ...d.rules] }))}>
                {t('platforms.addBaseRate')}
              </Button>
            </div>
          </Alert>
        ) : mode === 'custom' ? (
          <Alert tone="info" title={t('platforms.customTitle')} action={{ label: t('platforms.goRewards'), onClick: () => goTo('rewards') }}>
            {t('platforms.customBody')}
          </Alert>
        ) : (
          <>
            <RadioGroup
              name="rate-mode"
              legend={t('platforms.rateModeLegend')}
              orientation="horizontal"
              value={mode}
              onValueChange={(v) => update((d) => setBaseRateMode(d, v === 'per_platform' ? 'per_platform' : 'same'))}
              options={[
                { value: 'same', label: t('platforms.modeSame') },
                { value: 'per_platform', label: t('platforms.modePerPlatform'), disabled: draft.platforms.length < 2 && mode !== 'per_platform' },
              ]}
            />
            {mode === 'same' ? (
              <div className="max-w-md">{rateField(null)}</div>
            ) : (
              <div className="grid gap-4 sm:grid-cols-2">{draft.platforms.map((p) => rateField(p))}</div>
            )}
          </>
        )}
        <p className="text-caption text-muted">{t('platforms.moreRules')}</p>
      </Section>
    </Lock>
  );
}
