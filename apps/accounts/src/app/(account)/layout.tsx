import { Suspense, type ReactNode } from 'react';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { Logo } from '@clipper/ui';
import { AccountNav, BackToApp } from '@/features/hub/account-nav';
import { ThemeSwitch } from '@/lib/theme-switch';

/** Shell halaman akun: header + sidebar (desktop) / tab atas (mobile). Login dijaga proxy + requireAccount per halaman. */
export default async function AccountLayout({ children }: { children: ReactNode }) {
  const t = await getTranslations('accounts.nav');
  return (
    <div className="bg-page min-h-dvh">
      <header className="sticky top-0 z-20 border-b border-border/70 bg-surface/85 pt-[var(--safe-top)] backdrop-blur-[14px] backdrop-saturate-150">
        <div className="mx-auto flex h-16 w-full max-w-[1200px] items-center gap-2 px-4 md:px-6">
          <Logo size={28} product={t('product')} href="/" linkAs={Link} />
          <div className="ml-auto flex items-center gap-1">
            <ThemeSwitch />
            <Suspense>
              <BackToApp />
            </Suspense>
          </div>
        </div>
        <div className="px-4 md:px-6 lg:hidden">
          <Suspense fallback={<div className="h-[52px]" />}>
            <AccountNav variant="tabs" />
          </Suspense>
        </div>
      </header>
      <div className="mx-auto flex w-full max-w-[1200px] gap-8 px-4 py-5 md:px-6 lg:py-8">
        <aside className="hidden w-60 shrink-0 lg:block">
          <div className="sticky top-24">
            <Suspense>
              <AccountNav variant="sidebar" />
            </Suspense>
          </div>
        </aside>
        <main id="main" className="min-w-0 flex-1 pb-[calc(var(--safe-bottom)+24px)]">
          {children}
        </main>
      </div>
    </div>
  );
}
