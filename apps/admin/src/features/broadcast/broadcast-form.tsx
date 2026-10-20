'use client';

import { useRef, useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, Checkbox, Field, Fieldset, Input, Select, Textarea, toast } from '@clipper/ui';
import { useErrorText } from '@/features/shared/use-error-text';
import { sendBroadcast } from './actions';
import { CHANNELS, PLATFORM_KEYS } from './segment';

export function BroadcastForm({ platformLabels, canSecurity }: { platformLabels: Record<string, string>; canSecurity: boolean }) {
  const t = useTranslations('admin.broadcast');
  const errorText = useErrorText();
  const ref = useRef<HTMLFormElement>(null);
  const [security, setSecurity] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  return (
    <form
      ref={ref}
      className="flex flex-col gap-5"
      onSubmit={(e) => {
        e.preventDefault();
        const fd = new FormData(e.currentTarget);
        start(async () => {
          setError(null);
          const r = await sendBroadcast(fd);
          if (!r.ok) return setError(errorText(r.error));
          toast.success(t('scheduled'));
          ref.current?.reset();
        });
      }}
    >
      {error ? <Alert tone="danger">{error}</Alert> : null}
      {canSecurity ? (
        <Checkbox
          name="security"
          checked={security}
          onCheckedChange={(v) => setSecurity(v === true)}
          label={t('securityLabel')}
          description={t('securityHelp')}
        />
      ) : null}
      <Field label={t('fTitle')} required>
        <Input name="title" required minLength={3} maxLength={120} />
      </Field>
      <Field label={t('fBody')} required>
        <Textarea name="body" required maxLength={2000} showCount rows={4} />
      </Field>
      {security ? null : (
        <Fieldset legend={t('segment')} description={t('segmentHelp')}>
          <div className="flex flex-col gap-4">
            <div className="flex flex-wrap gap-x-5 gap-y-2">
              {PLATFORM_KEYS.map((p) => (
                <Checkbox key={p} name={`platform_${p}`} label={platformLabels[p] ?? p} />
              ))}
            </div>
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <Field label={t('minTrust')} optional>
                <Input name="min_trust_score" type="number" min={0} max={100} step={1} />
              </Field>
              <Field label={t('maxTrust')} optional>
                <Input name="max_trust_score" type="number" min={0} max={100} step={1} />
              </Field>
              <Field label={t('kyc')}>
                <Select
                  name="kyc"
                  defaultValue="any"
                  options={[
                    { value: 'any', label: t('kycAny') },
                    { value: 'approved', label: t('kycApproved') },
                    { value: 'not_approved', label: t('kycNotApproved') },
                  ]}
                />
              </Field>
              <Field label={t('activeDays')} optional helper={t('activeDaysHelp')}>
                <Input name="active_days" type="number" min={1} max={3650} step={1} />
              </Field>
            </div>
          </div>
        </Fieldset>
      )}
      <Fieldset legend={t('channels')}>
        <div className="flex flex-wrap gap-x-5 gap-y-2">
          {CHANNELS.map((c) => (
            <Checkbox key={c} name={`channel_${c}`} label={t(`channel.${c}`)} defaultChecked={c === 'in_app'} />
          ))}
        </div>
      </Fieldset>
      <Field label={t('schedule')} optional helper={t('scheduleHelp')} className="sm:max-w-xs">
        <Input name="scheduled_at" type="datetime-local" />
      </Field>
      <div>
        <Button type="submit" iconLeft="send" loading={pending}>
          {t('submit')}
        </Button>
      </div>
    </form>
  );
}
