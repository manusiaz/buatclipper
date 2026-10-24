'use client';

import { Alert, RadioGroup, Switch } from '@clipper/ui';
import { VISIBILITIES } from '../constants';
import { Lock, NumberField, Section } from '../parts';
import type { Visibility } from '../types';
import type { StepProps } from './shared';

export function EligibilityStep({ draft, update, locked, t, locale, errorOf }: StepProps) {
  return (
    <Lock disabled={locked}>
      <Section title={t('eligibility.section')} description={t('stepHints.eligibility')}>
        <div className="grid gap-4 sm:grid-cols-2">
          <NumberField
            label={t('eligibility.minFollowers')}
            value={draft.min_followers}
            onChange={(min_followers) => update((d) => ({ ...d, min_followers }))}
            locale={locale}
            suffix={t('common.followers')}
            helper={t('eligibility.minFollowersHelper')}
            error={errorOf('min_followers')}
          />
          <NumberField
            label={t('eligibility.accountAge')}
            value={draft.min_account_age_days}
            onChange={(min_account_age_days) => update((d) => ({ ...d, min_account_age_days }))}
            locale={locale}
            suffix={t('common.days')}
            helper={t('eligibility.accountAgeHelper')}
            error={errorOf('min_account_age_days')}
          />
          <NumberField
            label={t('eligibility.trust')}
            value={draft.min_trust_score}
            onChange={(min_trust_score) => update((d) => ({ ...d, min_trust_score }))}
            locale={locale}
            suffix="/ 100"
            helper={t('eligibility.trustHelper')}
            error={errorOf('min_trust_score')}
          />
        </div>
        <Switch
          label={t('eligibility.kyc')}
          description={t('eligibility.kycHint')}
          checked={draft.kyc_required}
          onCheckedChange={(kyc_required) => update((d) => ({ ...d, kyc_required }))}
        />
      </Section>

      <Section title={t('eligibility.visibility')} description={t('eligibility.visibilityHint')}>
        <RadioGroup
          name="visibility"
          legend={t('eligibility.visibility')}
          variant="card"
          value={draft.visibility}
          onValueChange={(v) => update((d) => ({ ...d, visibility: v as Visibility }))}
          options={VISIBILITIES.map((v) => ({ value: v, label: t(`visibilities.${v}`), description: t(`visibilityHints.${v}`) }))}
        />
        {draft.visibility === 'invite' ? (
          <Alert tone="info" title={t('eligibility.inviteTitle')}>
            {t('eligibility.inviteBody')}
          </Alert>
        ) : null}
      </Section>
    </Lock>
  );
}
