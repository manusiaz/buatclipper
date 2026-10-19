'use client';

import { Field, Input, RadioGroup } from '@clipper/ui';
import { REVIEW_MODES } from '../constants';
import { daysBetween, fromWibInput, toWibInput } from '../datetime';
import { Lock, NumberField, Section } from '../parts';
import type { ReviewMode } from '../types';
import type { StepProps } from './shared';

export function ScheduleStep({ draft, update, locked, t, locale, errorOf }: StepProps) {
  const span = daysBetween(draft.start_at, draft.submit_deadline);
  return (
    <Lock disabled={locked}>
      <Section title={t('schedule.section')} description={t('stepHints.schedule')}>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label={t('schedule.startAt')} required helper={t('schedule.startHelper')} error={errorOf('start_at')}>
            <Input
              type="datetime-local"
              value={toWibInput(draft.start_at)}
              suffix="WIB"
              onChange={(e) => {
                const start_at = fromWibInput(e.target.value);
                update((d) => ({ ...d, start_at }));
              }}
            />
          </Field>
          <Field label={t('schedule.deadline')} required helper={t('schedule.deadlineHelper')} error={errorOf('submit_deadline')}>
            <Input
              type="datetime-local"
              value={toWibInput(draft.submit_deadline)}
              min={toWibInput(draft.start_at) || undefined}
              suffix="WIB"
              onChange={(e) => {
                const submit_deadline = fromWibInput(e.target.value);
                update((d) => ({ ...d, submit_deadline }));
              }}
            />
          </Field>
        </div>
        {span != null && span >= 0 ? <p className="text-caption text-muted">{t('schedule.span', { days: span })}</p> : null}
        <NumberField
          label={t('schedule.viewWindow')}
          value={draft.view_window_days}
          onChange={(view_window_days) => update((d) => ({ ...d, view_window_days }))}
          locale={locale}
          suffix={t('common.days')}
          required
          helper={t('schedule.viewWindowHelper')}
          error={errorOf('view_window_days')}
          className="sm:max-w-xs"
        />
      </Section>

      <Section title={t('schedule.reviewMode')} description={t('schedule.reviewModeHint')}>
        <RadioGroup
          name="review-mode"
          legend={t('schedule.reviewMode')}
          variant="card"
          value={draft.review_mode}
          onValueChange={(v) => update((d) => ({ ...d, review_mode: v as ReviewMode }))}
          options={REVIEW_MODES.map((m) => ({ value: m, label: t(`reviewModes.${m}`), description: t(`reviewHints.${m}`) }))}
        />
      </Section>
    </Lock>
  );
}
