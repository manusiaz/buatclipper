'use client';

import { useActionState, useState } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, Card, Checkbox, Field, Input, RadioGroup, Textarea } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { createOrg, type CreateOrgState } from './actions';

export function CreateOrgForm({ kycApproved }: { kycApproved: boolean }) {
  const t = useTranslations('brand.newOrg');
  const errText = useErrorText();
  const [state, action, pending] = useActionState<CreateOrgState, FormData>(createOrg, null);
  const [type, setType] = useState<'badan' | 'perorangan'>('badan');
  const [agency, setAgency] = useState(false);
  const [npwp, setNpwp] = useState('');
  const fieldErr = (f: string) => (state?.field === f && state.error ? errText(state.error) : undefined);
  const npwpDigits = npwp.replace(/\D/g, '');
  const npwpBad = npwpDigits.length > 0 && !/^\d{15,16}$/.test(npwpDigits);

  return (
    <Card padding="lg">
      <form action={action} className="flex flex-col gap-5" noValidate>
        {state?.error && !state.field ? <Alert tone="danger">{errText(state.error)}</Alert> : null}
        <Field label={t('name')} helper={t('nameHelp')} error={fieldErr('name')} required>
          <Input name="name" maxLength={100} minLength={2} autoComplete="organization" />
        </Field>
        <RadioGroup
          name="org_type"
          legend={t('type')}
          legendVisible
          variant="card"
          value={type}
          onValueChange={(v) => setType(v === 'perorangan' ? 'perorangan' : 'badan')}
          options={[
            { value: 'badan', label: t('typeBadan'), description: t('typeBadanHelp') },
            { value: 'perorangan', label: t('typePerorangan'), description: t('typePeroranganHelp') },
          ]}
        />
        {type === 'badan' ? (
          <>
            <Field label={t('legalName')} error={fieldErr('legal_name')} required>
              <Input name="legal_name" maxLength={200} />
            </Field>
            <Field
              label={t('npwp')}
              helper={t('npwpHelp')}
              error={fieldErr('npwp') ?? (npwpBad ? t('npwpInvalid') : undefined)}
              labelAside={npwpDigits ? t('digits', { count: npwpDigits.length }) : undefined}
              required
            >
              <Input name="npwp" inputMode="numeric" value={npwp} onChange={(e) => setNpwp(e.target.value)} maxLength={20} />
            </Field>
            <Field label={t('address')} error={fieldErr('address')} required>
              <Textarea name="address" rows={3} maxLength={500} />
            </Field>
          </>
        ) : (
          <Alert tone="info" title={t('peroranganTitle')}>
            {kycApproved ? t('peroranganKycDone') : t('peroranganBody')}
          </Alert>
        )}
        <Checkbox
          checked={agency}
          onCheckedChange={(v) => setAgency(v === true)}
          label={t('agency')}
          description={t('agencyHelp')}
        />
        {agency ? <input type="hidden" name="is_agency" value="on" /> : null}
        <Alert tone="warn">{t('verifyNote')}</Alert>
        <div className="flex justify-end">
          <Button type="submit" size="lg" loading={pending} disabled={npwpBad} iconRight="arrow_forward" className="max-sm:w-full">
            {t('submit')}
          </Button>
        </div>
      </form>
    </Card>
  );
}
