'use client';

import { useEffect, useRef, useState, useTransition, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, Checkbox, Field, Fieldset, Input } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error-text';
import { checkUsername, completeOnboarding, type UsernameCheck } from './actions';
import { DISPLAY_NAME_MAX, normalizeUsername, USERNAME_RE, type LegalDoc, type Role } from './rules';

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
      const r = await completeOnboarding({
        role,
        username,
        displayName,
        tosVersion: tos.version,
        privacyVersion: privacy.version,
        adult,
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
