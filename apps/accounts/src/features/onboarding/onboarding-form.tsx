'use client';

import { useEffect, useMemo, useRef, useState, useTransition, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Avatar, Button, Checkbox, Field, Fieldset, Input } from '@clipper/ui';
import { fitImage, putSigned } from '@/lib/upload';
import { useErrorText } from '@/lib/use-error-text';
import { avatarUploadUrl, checkUsername, completeOnboarding, type UsernameCheck } from './actions';
import { DISPLAY_NAME_MAX, normalizeUsername, USERNAME_RE, type LegalDoc, type Role } from './rules';

const AVATAR_MAX = 1024 * 1024; // = file_size_limit bucket avatars

export interface OnboardingFormProps {
  role: Role;
  dest: string;
  defaultUsername: string;
  defaultDisplayName: string;
  tos: LegalDoc;
  privacy: LegalDoc;
}

export function OnboardingForm({ role, dest, defaultUsername, defaultDisplayName, tos, privacy }: OnboardingFormProps) {
  const t = useTranslations('accounts.onboarding');
  const errText = useErrorText();
  const [username, setUsername] = useState(defaultUsername);
  const [check, setCheck] = useState<UsernameCheck | 'checking' | null>(null);
  const [displayName, setDisplayName] = useState(defaultDisplayName);
  const [adult, setAdult] = useState(false);
  const [tosOk, setTosOk] = useState(false);
  const [privacyOk, setPrivacyOk] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [leaving, setLeaving] = useState(false);
  const [pending, start] = useTransition();
  const seq = useRef(0);
  const [avatar, setAvatar] = useState<File | null>(null);
  const preview = useMemo(() => (avatar ? URL.createObjectURL(avatar) : null), [avatar]);
  useEffect(() => () => void (preview && URL.revokeObjectURL(preview)), [preview]);
  const fileRef = useRef<HTMLInputElement>(null);
  // Onboarding gagal setelah unggah (mis. username diambil orang) → kirim ulang tanpa unggah ulang.
  const uploaded = useRef<{ file: File; path: string } | null>(null);

  useEffect(() => {
    const u = normalizeUsername(username);
    const n = ++seq.current;
    if (!u) return setCheck(null);
    if (!USERNAME_RE.test(u)) return setCheck({ status: 'invalid', suggestions: [] });
    setCheck('checking');
    const id = setTimeout(() => {
      checkUsername(u)
        .catch(() => null)
        .then((r) => n === seq.current && setCheck(r));
    }, 400);
    return () => clearTimeout(id);
  }, [username]);

  const ready =
    typeof check === 'object' && check?.status === 'ok' && !!displayName.trim() && tosOk && privacyOk && (role === 'brand' || adult);

  const submit = () =>
    start(async () => {
      setError(null);
      let avatarPath = avatar && uploaded.current?.file === avatar ? uploaded.current.path : undefined;
      if (avatar && !avatarPath) {
        try {
          const blob = await fitImage(avatar, AVATAR_MAX, 512);
          const up = await avatarUploadUrl(blob.type);
          if (!up.ok) return setError(up.error);
          await putSigned(up.signedUrl, blob, process.env.NEXT_PUBLIC_CORE_PUBLISHABLE_KEY!);
          uploaded.current = { file: avatar, path: up.path };
          avatarPath = up.path;
        } catch (e) {
          return setError(e instanceof Error && /^(file_type|file_too_large)$/.test(e.message) ? e.message : 'upload_failed');
        }
      }
      const r = await completeOnboarding({
        role,
        username,
        displayName,
        tosVersion: tos.version,
        privacyVersion: privacy.version,
        adult,
        avatarPath,
        dest,
      });
      if (!r.ok) {
        setError(r.error);
        if (r.error === 'username_taken') setCheck({ status: 'taken', suggestions: [] });
        return;
      }
      setLeaving(true);
      window.location.assign(r.redirect);
    });

  const docLink = (doc: LegalDoc) => (chunks: ReactNode) => (
    <a href={doc.url} target="_blank" rel="noopener noreferrer" className="text-link underline underline-offset-2 focus-ring">
      {chunks}
    </a>
  );

  const usernameState = check === 'checking' ? null : check;

  return (
    <form
      className="flex flex-col gap-5"
      onSubmit={(e) => {
        e.preventDefault();
        if (ready) submit();
      }}
    >
      {error && <Alert tone="danger">{errText(error)}</Alert>}

      <div className="flex items-center gap-4">
        <Avatar name={displayName.trim() || username || '?'} src={preview} size={64} />
        <div className="flex min-w-0 flex-col gap-1.5">
          <span className="text-label text-ink">
            {t('avatar')} <span className="font-medium text-muted">{t('avatarOptional')}</span>
          </span>
          <div className="flex flex-wrap gap-2">
            <Button type="button" variant="secondary" size="sm" iconLeft="photo_camera" onClick={() => fileRef.current?.click()}>
              {avatar ? t('avatarChange') : t('avatarPick')}
            </Button>
            {avatar && (
              <Button type="button" variant="ghost" size="sm" onClick={() => setAvatar(null)}>
                {t('avatarRemove')}
              </Button>
            )}
          </div>
        </div>
        <input
          ref={fileRef}
          type="file"
          accept="image/*"
          hidden
          onChange={(e) => {
            setAvatar(e.target.files?.[0] ?? null);
            e.target.value = '';
          }}
        />
      </div>

      <div className="flex flex-col gap-2">
        <Field
          label={t('username')}
          required
          helper={check === 'checking' ? t('usernameChecking') : t('usernameHelper')}
          error={
            usernameState?.status === 'taken' ? t('usernameTaken') : usernameState?.status === 'invalid' ? t('usernameInvalid') : undefined
          }
          success={usernameState?.status === 'ok' ? t('usernameOk') : undefined}
        >
          <Input
            prefix="@"
            value={username}
            onChange={(e) => setUsername(e.target.value.toLowerCase().replace(/\s/g, ''))}
            maxLength={30}
            autoComplete="username"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
          />
        </Field>
        {usernameState?.status === 'taken' && usernameState.suggestions.length > 0 && (
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-caption text-muted">{t('suggestions')}</span>
            {usernameState.suggestions.map((s) => (
              <Button key={s} type="button" variant="tertiary" size="sm" onClick={() => setUsername(s)}>
                @{s}
              </Button>
            ))}
          </div>
        )}
      </div>

      <Field label={t('displayName')} required helper={t('displayNameHelper')}>
        <Input value={displayName} onChange={(e) => setDisplayName(e.target.value)} maxLength={DISPLAY_NAME_MAX} autoComplete="nickname" />
      </Field>

      <Fieldset legend={t('consents')}>
        {role === 'clipper' && (
          <Checkbox checked={adult} onCheckedChange={(v) => setAdult(v === true)} label={t('adult')} description={t('adultHelper')} required />
        )}
        <Checkbox
          checked={tosOk}
          onCheckedChange={(v) => setTosOk(v === true)}
          label={t.rich(role === 'clipper' ? 'tosClipper' : 'tosBrand', { link: docLink(tos), version: tos.version })}
          required
        />
        <Checkbox
          checked={privacyOk}
          onCheckedChange={(v) => setPrivacyOk(v === true)}
          label={t.rich('privacy', { link: docLink(privacy), version: privacy.version })}
          description={t('privacyHelper')}
          required
        />
      </Fieldset>

      <Button type="submit" size="lg" fullWidth loading={pending || leaving} disabled={!ready}>
        {role === 'clipper' ? t('submitClipper') : t('submitBrand')}
      </Button>
    </form>
  );
}
