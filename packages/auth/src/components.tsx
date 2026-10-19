'use client';

// Komponen login bersama accounts.{domain}, app.{domain} (PWA iOS, §15.6) dan admin.{domain}: email → kode OTP (atau
// Google), admin lanjut TOTP. Semua langkah = Server Action, jadi cookie sesi diset server (httpOnly).
import { useEffect, useRef, useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, CopyField, Field, Input } from '@clipper/ui';
import { googleSignIn, mfaEnroll, mfaVerify, sendOtp, verifyOtp } from './actions';
import type { SessionKind } from './index';

type Step = 'email' | 'code' | 'mfa_enroll' | 'mfa_challenge';

export interface LoginFormProps {
  kind: SessionKind;
  next?: string;
  /** Google hanya di accounts & app (bukan admin). */
  google?: boolean;
  turnstileSiteKey?: string;
  /** Kode error dari query (?error=oauth). */
  initialError?: string;
}

const RESEND_SECONDS = 30;

export function LoginForm({ kind, next, google = kind === 'sso', turnstileSiteKey, initialError }: LoginFormProps) {
  const t = useTranslations('auth');
  const [step, setStep] = useState<Step>('email');
  const [email, setEmail] = useState('');
  const [code, setCode] = useState('');
  const [error, setError] = useState<string | null>(initialError ?? null);
  const [captcha, setCaptcha] = useState<string | undefined>();
  const [resendIn, setResendIn] = useState(0);
  const [pending, start] = useTransition();

  useEffect(() => {
    if (resendIn <= 0) return;
    const id = setTimeout(() => setResendIn((s) => s - 1), 1000);
    return () => clearTimeout(id);
  }, [resendIn]);

  const go = (url: string) => window.location.assign(url);

  const send = () =>
    start(async () => {
      setError(null);
      const r = await sendOtp(kind, email, captcha);
      if (!r.ok) return setError(r.error);
      setStep('code');
      setResendIn(RESEND_SECONDS);
    });

  const verify = () =>
    start(async () => {
      setError(null);
      const r = await verifyOtp(kind, email, code, next);
      if (!r.ok) return setError(r.error);
      if (r.step) return setStep(r.step);
      if (r.redirect) go(r.redirect);
    });

  const withGoogle = () =>
    start(async () => {
      setError(null);
      const r = await googleSignIn(window.location.origin, next);
      if (!r.ok || !r.redirect) return setError(r.ok ? 'oauth' : r.error);
      go(r.redirect);
    });

  if (step === 'mfa_enroll' || step === 'mfa_challenge') {
    return <MfaPanel kind={kind} mode={step === 'mfa_enroll' ? 'enroll' : 'challenge'} next={next} />;
  }

  return (
    <div className="flex flex-col gap-5">
      {error && <Alert tone="danger">{t(`errors.${error}` as 'errors.generic')}</Alert>}
      {step === 'email' ? (
        <form
          className="flex flex-col gap-4"
          onSubmit={(e) => {
            e.preventDefault();
            send();
          }}
        >
          <Field label={t('email')} required>
            <Input
              type="email"
              autoComplete="email"
              inputMode="email"
              placeholder={t('emailPlaceholder')}
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoFocus
            />
          </Field>
          {turnstileSiteKey && <Turnstile siteKey={turnstileSiteKey} onToken={setCaptcha} />}
          <Button type="submit" fullWidth loading={pending} disabled={!email || (!!turnstileSiteKey && !captcha)}>
            {t('sendCode')}
          </Button>
          {google && (
            <>
              <div className="flex items-center gap-3 text-caption text-muted">
                <span className="h-px flex-1 bg-border" />
                {t('orContinue')}
                <span className="h-px flex-1 bg-border" />
              </div>
              <Button type="button" variant="secondary" fullWidth onClick={withGoogle} disabled={pending}>
                {t('google')}
              </Button>
            </>
          )}
        </form>
      ) : (
        <form
          className="flex flex-col gap-4"
          onSubmit={(e) => {
            e.preventDefault();
            verify();
          }}
        >
          <p className="text-body-s text-text-2">{t('codeSentTo', { email })}</p>
          <Field label={t('code')} required helper={t('spamHint')}>
            <Input
              inputMode="numeric"
              autoComplete="one-time-code"
              pattern="[0-9]{6}"
              maxLength={6}
              value={code}
              onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))}
              className="tnum tracking-[0.4em]"
              autoFocus
            />
          </Field>
          <Button type="submit" fullWidth loading={pending} disabled={code.length !== 6}>
            {t('verify')}
          </Button>
          <div className="flex items-center justify-between text-body-s">
            <Button type="button" variant="link" size="sm" onClick={() => setStep('email')}>
              {t('changeEmail')}
            </Button>
            <Button type="button" variant="link" size="sm" disabled={resendIn > 0 || pending} onClick={send}>
              {resendIn > 0 ? t('resendIn', { seconds: resendIn }) : t('resend')}
            </Button>
          </div>
        </form>
      )}
    </div>
  );
}

export interface MfaPanelProps {
  kind: SessionKind;
  mode: 'enroll' | 'challenge';
  next?: string;
  /** Dipanggil setelah verifikasi sukses; default = navigasi ke redirect dari server. */
  onDone?: () => void;
}

/** Daftar TOTP (QR + kunci manual) atau minta kode TOTP → sesi aal2. */
export function MfaPanel({ kind, mode, next, onDone }: MfaPanelProps) {
  const t = useTranslations('auth');
  const [enroll, setEnroll] = useState<{ factorId: string; qr: string; secret: string } | null>(null);
  const [code, setCode] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const started = useRef(false);

  useEffect(() => {
    if (mode !== 'enroll' || started.current) return;
    started.current = true;
    start(async () => {
      const r = await mfaEnroll(kind);
      if (r.ok) setEnroll(r);
      else setError(r.error);
    });
  }, [kind, mode]);

  const verify = () =>
    start(async () => {
      setError(null);
      const r = await mfaVerify(kind, code, enroll?.factorId, next);
      if (!r.ok) return setError(r.error);
      if (onDone) onDone();
      else if (r.redirect) window.location.assign(r.redirect);
    });

  return (
    <form
      className="flex flex-col gap-4"
      onSubmit={(e) => {
        e.preventDefault();
        verify();
      }}
    >
      <div>
        <h2 className="text-h5 text-ink">{mode === 'enroll' ? t('mfaEnrollTitle') : t('mfaTitle')}</h2>
        {mode === 'enroll' && <p className="mt-1 text-body-s text-text-2">{t('mfaEnrollBody')}</p>}
      </div>
      {error && <Alert tone="danger">{t(`errors.${error}` as 'errors.generic')}</Alert>}
      {mode === 'enroll' && enroll && (
        <div className="flex flex-col items-center gap-3">
          {/* QR = data URL SVG dari Supabase Auth (bukan input user). */}
          <img src={enroll.qr} alt="" width={176} height={176} className="rounded-card-sm bg-white p-2 shadow-card" />
          <CopyField label={t('mfaSecret')} value={enroll.secret} mono className="w-full" />
        </div>
      )}
      <Field label={t('mfaCode')} required>
        <Input
          inputMode="numeric"
          autoComplete="one-time-code"
          maxLength={6}
          value={code}
          onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))}
          className="tnum tracking-[0.4em]"
          autoFocus
        />
      </Field>
      <Button type="submit" fullWidth loading={pending} disabled={code.length !== 6 || (mode === 'enroll' && !enroll)}>
        {t('mfaVerify')}
      </Button>
    </form>
  );
}

declare global {
  interface Window {
    turnstile?: { render: (el: HTMLElement, opts: Record<string, unknown>) => string; remove: (id: string) => void };
  }
}

/** Cloudflare Turnstile (CAPTCHA Auth identity, §15.6). Script dimuat dinamis → lolos CSP 'strict-dynamic'. */
function Turnstile({ siteKey, onToken }: { siteKey: string; onToken: (t: string | undefined) => void }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    let id: string | undefined;
    const mount = () => {
      if (ref.current && window.turnstile) {
        id = window.turnstile.render(ref.current, {
          sitekey: siteKey,
          callback: (token: string) => onToken(token),
          'expired-callback': () => onToken(undefined),
        });
      }
    };
    if (window.turnstile) mount();
    else {
      const s = document.createElement('script');
      s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
      s.async = true;
      s.onload = mount;
      document.head.appendChild(s);
    }
    return () => {
      if (id) window.turnstile?.remove(id);
    };
  }, [siteKey, onToken]);
  return <div ref={ref} className="min-h-[65px]" />;
}
