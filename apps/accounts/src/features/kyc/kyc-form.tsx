'use client';

import { useEffect, useMemo, useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, Checkbox, Field, Icon, Input, formatDate, toast } from '@clipper/ui';
import { fitImage, putSigned } from '@/lib/upload';
import { useErrorText } from '@/lib/use-error-text';
import { kycUploadUrl, submitKyc } from './actions';
import { checkNik, cleanNik } from './nik';

const MAX_BYTES = 5 * 1024 * 1024;
const NAME_RE = /^[\p{L}\p{M}][\p{L}\p{M} .,'-]*$/u;

export function KycForm({ defaultName }: { defaultName: string }) {
  const t = useTranslations('accounts.kyc');
  const errText = useErrorText();
  const [name, setName] = useState(defaultName);
  const [nik, setNik] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const [consent, setConsent] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [step, setStep] = useState<'upload' | 'submit' | null>(null);
  const [pending, start] = useTransition();
  const preview = useMemo(() => (file ? URL.createObjectURL(file) : null), [file]);
  useEffect(() => () => void (preview && URL.revokeObjectURL(preview)), [preview]);

  const cleanName = name.trim().replace(/\s+/g, ' ');
  const nameOk = cleanName.length >= 2 && cleanName.length <= 100 && NAME_RE.test(cleanName);
  const nikCheck = nik.length === 16 ? checkNik(nik) : null;
  const ready = nameOk && nikCheck?.ok === true && !!file && consent;

  const nikHint = () => {
    if (!nikCheck) return { helper: t('nikHelper') };
    if (nikCheck.ok) {
      const born = formatDate(Date.UTC(nikCheck.birth.y, nikCheck.birth.m - 1, nikCheck.birth.d));
      return { success: t('nikBirth', { date: born, age: nikCheck.age }) };
    }
    return { error: nikCheck.error === 'under_age' ? t('nikUnderAge', { age: nikCheck.age }) : t('nikInvalid') };
  };

  const submit = () =>
    start(async () => {
      setError(null);
      if (!file) return;
      try {
        setStep('upload');
        const blob = await fitImage(file, MAX_BYTES);
        const up = await kycUploadUrl(blob.type);
        if (!up.ok) return setError(up.error);
        await putSigned(up.signedUrl, blob, process.env.NEXT_PUBLIC_IDENTITY_PUBLISHABLE_KEY!);
        setStep('submit');
        const r = await submitKyc({ legalName: cleanName, nik, docPath: up.path });
        if (!r.ok) return setError(r.error);
        toast.success(t('submitted'));
      } catch (e) {
        setError(e instanceof Error && /^(file_type|file_too_large|upload_failed)$/.test(e.message) ? e.message : 'upload_failed');
      } finally {
        setStep(null);
      }
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

      <Field label={t('legalName')} required helper={t('legalNameHelper')} error={name && !nameOk ? t('legalNameInvalid') : undefined}>
        <Input value={name} onChange={(e) => setName(e.target.value)} maxLength={100} autoComplete="name" autoCapitalize="characters" />
      </Field>

      <Field label={t('nik')} required {...nikHint()}>
        <Input
          value={nik}
          onChange={(e) => setNik(cleanNik(e.target.value))}
          inputMode="numeric"
          autoComplete="off"
          maxLength={16}
          className="tnum tracking-[0.08em]"
          suffix={<span className="text-caption text-muted tnum">{nik.length}/16</span>}
        />
      </Field>

      <Field label={t('photo')} required helper={t('photoHelper')}>
        {({ invalid: _invalid, ...control }) => (
          <label
            htmlFor={control.id}
            className="flex min-h-24 cursor-pointer items-center gap-4 rounded-card-sm border-[1.5px] border-dashed border-border-strong bg-surface-2 p-4 transition-colors duration-120 focus-ring-within hover:border-primary"
          >
            {preview ? (
              <img src={preview} alt={t('photoPreview')} className="h-16 w-24 shrink-0 rounded-[8px] object-cover shadow-card" />
            ) : (
              <span className="grid size-12 shrink-0 place-items-center rounded-[30%] bg-primary-soft text-primary-soft-fg">
                <Icon name="photo_camera" size={24} filled />
              </span>
            )}
            <span className="flex min-w-0 flex-col">
              <span className="truncate text-label text-ink">{file ? file.name : t('photoPick')}</span>
              <span className="text-caption text-muted">{file ? t('photoChange') : t('photoTypes')}</span>
            </span>
            <input
              {...control}
              type="file"
              accept="image/jpeg,image/png,image/webp"
              className="sr-only"
              onChange={(e) => setFile(e.target.files?.[0] ?? null)}
            />
          </label>
        )}
      </Field>

      <Checkbox checked={consent} onCheckedChange={(v) => setConsent(v === true)} label={t('consent')} description={t('consentBody')} required />

      <Button type="submit" size="lg" fullWidth loading={pending} loadingText={step === 'upload' ? t('uploading') : t('sending')} disabled={!ready}>
        {t('submit')}
      </Button>
    </form>
  );
}
