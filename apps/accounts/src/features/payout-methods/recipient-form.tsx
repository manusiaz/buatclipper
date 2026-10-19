'use client';

import { useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, Checkbox, Field, Input, Textarea, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error-text';
import { saveRecipient } from './actions';
import type { RecipientField } from './rules';

const KNOWN = ['recipient_name', 'phone', 'address', 'city', 'postal_code', 'email'];
const MULTILINE = /address|alamat/;

export interface RecipientFormProps {
  rewardTypeId: string;
  fields: RecipientField[];
  shareActive: boolean;
  next?: string;
}

/** Field PII reward type (C6.1). Nilai lama tidak ditampilkan: identity tidak membuka data penerima ke browser. */
export function RecipientForm({ rewardTypeId, fields, shareActive, next }: RecipientFormProps) {
  const t = useTranslations('accounts.recipient');
  const errText = useErrorText();
  const [values, setValues] = useState<Record<string, string>>({});
  const [share, setShare] = useState(shareActive);
  const [error, setError] = useState<string | null>(null);
  const [leaving, setLeaving] = useState(false);
  const [pending, start] = useTransition();

  const label = (f: RecipientField) =>
    f.label ?? (KNOWN.includes(f.key) ? t(`fields.${f.key}`) : f.key.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase()));
  const ready = share && fields.every((f) => !f.required || values[f.key]?.trim());

  const submit = () =>
    start(async () => {
      setError(null);
      const r = await saveRecipient({ rewardTypeId, data: values, grantShare: !shareActive, next });
      if (!r.ok) return setError(r.error);
      if (r.redirect) {
        setLeaving(true);
        return window.location.assign(r.redirect);
      }
      toast.success(t('saved'));
    });

  return (
    <form
      className="flex flex-col gap-5"
      onSubmit={(e) => {
        e.preventDefault();
        if (ready) submit();
      }}
    >
      {error && <Alert tone="danger">{errText(error)}</Alert>}
      {fields.map((f) => {
        const set = (v: string) => setValues((s) => ({ ...s, [f.key]: v }));
        return (
          <Field key={f.key} label={label(f)} required={f.required} optional={!f.required}>
            {MULTILINE.test(f.key) ? (
              <Textarea value={values[f.key] ?? ''} onChange={(e) => set(e.target.value)} maxLength={500} rows={3} autoComplete="street-address" />
            ) : (
              <Input
                value={values[f.key] ?? ''}
                onChange={(e) => set(e.target.value)}
                maxLength={500}
                inputMode={f.key === 'phone' ? 'tel' : undefined}
                autoComplete={f.key === 'phone' ? 'tel' : f.key === 'postal_code' ? 'postal-code' : undefined}
              />
            )}
          </Field>
        );
      })}
      {shareActive ? (
        <p className="text-caption text-muted">{t('shareActive')}</p>
      ) : (
        <Checkbox checked={share} onCheckedChange={(v) => setShare(v === true)} label={t('share')} description={t('shareBody')} required />
      )}
      <Button type="submit" size="lg" fullWidth loading={pending || leaving} disabled={!ready}>
        {next ? t('saveAndBack') : t('save')}
      </Button>
    </form>
  );
}
