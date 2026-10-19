import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { redirect } from 'next/navigation';
import { getTranslations } from 'next-intl/server';
import { hosts, isAdmin, safeNext } from '@clipper/auth';
import { getAuth } from '@clipper/auth/server';
import { LoginForm } from '@clipper/auth/components';
import { AuthShell, ThemeToggle } from '@clipper/ui';

export const metadata: Metadata = { title: 'Masuk' };

type Props = { searchParams: Promise<{ next?: string; error?: string }> };

// C2.2: login di origin app — jalur PWA iOS (cookie PWA terpisah dari Safari, R-17).
export default async function LoginPage({ searchParams }: Props) {
  const sp = await searchParams;
  const next = safeNext(sp.next, '/campaigns');
  const { claims } = await getAuth('sso');
  if (claims && !isAdmin(claims)) redirect(next);
  const t = await getTranslations('auth');
  const link = (href: string) => (chunks: ReactNode) => (
    <a href={href} target="_blank" rel="noopener noreferrer" className="font-semibold text-link underline-offset-2 hover:underline">
      {chunks}
    </a>
  );
  return (
    <AuthShell
      title={t('title')}
      description={t('subtitle')}
      topRight={<ThemeToggle />}
      footer={t.rich('legal', { tos: link(`${hosts.web}/legal/tos_clipper`), privacy: link(`${hosts.web}/legal/privacy`) })}
    >
      <LoginForm
        kind="sso"
        google
        next={next}
        initialError={sp.error === 'oauth' ? 'oauth' : undefined}
        turnstileSiteKey={process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY || undefined}
      />
    </AuthShell>
  );
}
