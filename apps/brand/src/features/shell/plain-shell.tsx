import Link from 'next/link';
import type { ReactNode } from 'react';
import { getTranslations } from 'next-intl/server';
import { Container, Logo, ThemeToggle } from '@clipper/ui';
import { UserMenu } from './user-menu';

/** Kerangka halaman tanpa org (pemilih org, buat org). */
export async function PlainShell({ name, email, children }: { name: string; email?: string; children: ReactNode }) {
  const t = await getTranslations('brand.shell');
  return (
    <div className="bg-page min-h-dvh">
      <header className="sticky top-0 z-20 border-b border-border/70 bg-surface/85 pt-[var(--safe-top)] backdrop-blur-[14px]">
        <Container className="flex h-16 items-center gap-2">
          <Logo size={28} product={t('product')} href="/" linkAs={Link} />
          <div className="ml-auto flex items-center gap-1">
            <ThemeToggle labels={{ toggle: t('theme') }} />
            <UserMenu name={name} email={email} />
          </div>
        </Container>
      </header>
      <Container as="main" id="main" size="md" className="py-6 md:py-10">
        {children}
      </Container>
    </div>
  );
}
