import type { Metadata } from 'next';
import { redirect } from 'next/navigation';
import { getTranslations } from 'next-intl/server';
import { isAdmin } from '@clipper/auth';
import { mfaStatus } from '@clipper/auth/actions';
import { LoginForm, MfaPanel } from '@clipper/auth/components';
import { getAuth } from '@clipper/auth/server';
import { AuthShell, Logo, ThemeToggle } from '@clipper/ui';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('auth'))('adminTitle') };
}

// J-A1 A1.1: email → OTP → TOTP (daftar di login pertama). Sesi admin aal1 yang belum lulus TOTP langsung ke langkah MFA.
export default async function AdminLoginPage() {
  const [t, ta, { claims }] = await Promise.all([getTranslations('auth'), getTranslations('admin'), getAuth('admin')]);
  const admin = isAdmin(claims);
  if (admin && claims?.aal === 'aal2') redirect('/');
  const mfa = admin ? await mfaStatus('admin') : null;

  return (
    <AuthShell
      title={t('adminTitle')}
      description={ta('login.description')}
      logo={<Logo size={36} product="Admin" />}
      topRight={<ThemeToggle />}
      footer={ta('login.footer')}
    >
      {mfa ? (
        <MfaPanel kind="admin" mode={mfa.enrolled ? 'challenge' : 'enroll'} />
      ) : (
        <LoginForm kind="admin" google={false} turnstileSiteKey={process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY || undefined} />
      )}
    </AuthShell>
  );
}
