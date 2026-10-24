// C2.2 login native: email → kode OTP 6 digit (bukan magic link: link email terbuka di browser, bukan di app).
// Aturan sama dengan LoginForm web: kirim ulang 30 dtk, token Turnstile sekali pakai, akun admin ditolak.
import { useEffect, useState } from 'react';
import { KeyboardAvoidingView, Platform, View } from 'react-native';
import { useTranslations } from 'use-intl';
import { EMAIL, mapAuthError } from '@clipper/auth/otp';
import { decodeClaims, isAdmin } from '@/claims';
import { identity } from '@/supabase';
import { Turnstile, turnstileSiteKey } from '@/turnstile';
import { Alert, Button, Field, LogoMark, Txt } from '@/ui/core';
import { Screen } from '@/ui/screen';
import { useTheme } from '@/theme';

const RESEND_SECONDS = 30;

export default function Login() {
  const t = useTranslations('auth');
  const tm = useTranslations('clipper.mobile');
  const { c } = useTheme();
  const [step, setStep] = useState<'email' | 'code'>('email');
  const [email, setEmail] = useState('');
  const [code, setCode] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [captcha, setCaptcha] = useState<string | undefined>();
  const [round, setRound] = useState(0);
  const [resendIn, setResendIn] = useState(0);
  const [pending, setPending] = useState(false);

  useEffect(() => {
    if (resendIn <= 0) return;
    const id = setTimeout(() => setResendIn((s) => s - 1), 1000);
    return () => clearTimeout(id);
  }, [resendIn]);

  const send = async () => {
    setError(null);
    if (!EMAIL.test(email.trim())) return setError('invalid_email');
    setPending(true);
    const { error: e } = await identity.auth.signInWithOtp({
      email: email.trim().toLowerCase(),
      options: { shouldCreateUser: true, captchaToken: captcha },
    });
    setPending(false);
    if (turnstileSiteKey) {
      setCaptcha(undefined);
      setRound((n) => n + 1);
    }
    if (e) return setError(mapAuthError(e));
    setStep('code');
    setResendIn(RESEND_SECONDS);
  };

  const verify = async () => {
    setError(null);
    setPending(true);
    const { data, error: e } = await identity.auth.verifyOtp({ email: email.trim().toLowerCase(), token: code.trim(), type: 'email' });
    if (e || !data.session) {
      setPending(false);
      return setError(mapAuthError(e));
    }
    if (isAdmin(decodeClaims(data.session.access_token))) {
      await identity.auth.signOut({ scope: 'local' });
      setPending(false);
      return setError('admin_elsewhere');
    }
    // Sesi tersimpan → AuthProvider (onAuthStateChange) membuka tab atau onboarding.
  };

  const needCaptcha = !!turnstileSiteKey && !captcha;
  return (
    <KeyboardAvoidingView style={{ flex: 1, backgroundColor: c.canvas }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
      <Screen>
        <View style={{ gap: 6, marginTop: 24, marginBottom: 8 }}>
          <LogoMark size={52} />
          <Txt variant="h3" accessibilityRole="header">{tm('loginTitle')}</Txt>
          <Txt variant="body" tone="muted">{tm('loginBody')}</Txt>
        </View>
        {error ? <Alert tone="danger">{t(`errors.${error}` as 'errors.generic')}</Alert> : null}
        {step === 'email' ? (
          <>
            <Field
              label={t('email')}
              placeholder={t('emailPlaceholder')}
              value={email}
              onChangeText={setEmail}
              autoCapitalize="none"
              autoComplete="email"
              keyboardType="email-address"
              textContentType="emailAddress"
              autoFocus
              onSubmitEditing={send}
            />
            <Turnstile round={round} onToken={setCaptcha} />
            <Button full size="lg" loading={pending} disabled={!email || needCaptcha} onPress={send} testID="send-code">
              {t('sendCode')}
            </Button>
          </>
        ) : (
          <>
            <Txt variant="bodyS" tone="text2">{t('codeSentTo', { email })}</Txt>
            <Field
              label={t('code')}
              helper={t('spamHint')}
              value={code}
              onChangeText={(v) => setCode(v.replace(/\D/g, '').slice(0, 6))}
              keyboardType="number-pad"
              autoComplete="one-time-code"
              textContentType="oneTimeCode"
              maxLength={6}
              autoFocus
              style={{ letterSpacing: 8, fontSize: 22 }}
              onSubmitEditing={verify}
            />
            <Button full size="lg" loading={pending} disabled={code.length !== 6} onPress={verify} testID="verify-code">
              {t('verify')}
            </Button>
            <Turnstile round={round} onToken={setCaptcha} />
            <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
              <Button variant="link" onPress={() => setStep('email')}>{t('changeEmail')}</Button>
              <Button variant="link" disabled={resendIn > 0 || pending || needCaptcha} onPress={send}>
                {resendIn > 0 ? t('resendIn', { seconds: resendIn }) : t('resend')}
              </Button>
            </View>
          </>
        )}
      </Screen>
    </KeyboardAvoidingView>
  );
}
