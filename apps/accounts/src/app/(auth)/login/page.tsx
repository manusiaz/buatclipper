import type { ReactNode } from 'react';
import type { Metadata } from 'next';
import { redirect } from 'next/navigation';
import { getTranslations } from 'next-intl/server';
import { hosts, isAdmin, safeNext } from '@clipper/auth';
import { LoginForm } from '@clipper/auth/components';
import { getAuth } from '@clipper/auth/server';
import { AuthShell } from '@clipper/ui';
import { roleOf } from '@/features/onboarding/rules';
import { ThemeSwitch } from '@/lib/theme-switch';
import { one, type SearchParams } from '@/lib/url';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('accounts.meta'))('login') };
}

export default async function LoginPage({ searchParams }: { searchParams: SearchParams }) {
  const sp = await searchParams;
  const next = one(sp.next);
  const { claims } = await getAuth('sso');
  if (claims && !isAdmin(claims)) redirect(safeNext(next));

  const t = await getTranslations('auth');
  const error = one(sp.error);
  const tosDoc = roleOf(undefined, next, hosts.brand) === 'brand' ? 'tos-brand' : 'tos-clipper';
  const legalLink = (doc: string) => (chunks: ReactNode) => (
    <a href={`${hosts.web}/legal/${doc}`} className="font-semibold text-link underline-offset-2 hover:underline focus-ring">
      {chunks}
    </a>
  );

  return (
    <AuthShell
      title={t('title')}
      description={t('subtitle')}
      topRight={<ThemeSwitch />}
      footer={<p className="max-w-[40ch]">{t.rich('legal', { tos: legalLink(tosDoc), privacy: legalLink('privacy') })}</p>}
    >
      <LoginForm
        kind="sso"
        next={next}
        google
        turnstileSiteKey={process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY}
        initialError={error ? (t.has(`errors.${error}`) ? error : 'generic') : undefined}
      />
    </AuthShell>
  );
}
