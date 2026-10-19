'use client';

import Link from 'next/link';
import { usePathname, useSearchParams } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { safeNext } from '@clipper/auth';
import { Button, cn, Icon, type IconName } from '@clipper/ui';
import { withParams } from '@/lib/url';

const ITEMS: { href: string; key: string; icon: IconName }[] = [
  { href: '/', key: 'hub', icon: 'space_dashboard' },
  { href: '/kyc', key: 'kyc', icon: 'id_card' },
  { href: '/payout-methods', key: 'payoutMethods', icon: 'account_balance' },
  { href: '/security', key: 'security', icon: 'shield' },
  { href: '/privacy', key: 'privacy', icon: 'lock' },
];

const isActive = (path: string, href: string) => (href === '/' ? path === '/' : path === href || path.startsWith(`${href}/`));

/** Menu akun §6.8: sidebar (≥ 1024 px) atau tab atas yang bisa digeser (mobile). `next` ikut di setiap link. */
export function AccountNav({ variant }: { variant: 'sidebar' | 'tabs' }) {
  const t = useTranslations('accounts.nav');
  const path = usePathname();
  const next = useSearchParams().get('next');
  const sidebar = variant === 'sidebar';

  return (
    <nav aria-label={t('label')}>
      <ul className={cn(sidebar ? 'flex flex-col gap-0.5' : 'no-scrollbar -mx-4 flex gap-1 overflow-x-auto px-4 pb-2')}>
        {ITEMS.map((item) => {
          const active = isActive(path, item.href);
          return (
            <li key={item.href} className="shrink-0">
              <Link
                href={withParams(item.href, { next })}
                aria-current={active ? 'page' : undefined}
                className={cn(
                  'flex items-center gap-2 font-semibold whitespace-nowrap text-text-2 transition-colors duration-120 focus-ring hover:bg-subtle hover:text-ink',
                  sidebar
                    ? 'h-11 gap-3 rounded-[10px] px-3 text-sm aria-[current=page]:bg-primary-tint aria-[current=page]:font-bold aria-[current=page]:text-primary-soft-fg aria-[current=page]:shadow-[inset_3px_0_0_var(--color-primary)]'
                    : 'h-11 rounded-full px-4 text-sm aria-[current=page]:bg-primary-soft aria-[current=page]:font-bold aria-[current=page]:text-primary-soft-fg',
                )}
              >
                <Icon name={item.icon} size={sidebar ? 20 : 18} filled={active} />
                {t(item.key)}
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}

/** "Kembali ke app" → next (bila sah) atau app.{domain}/campaigns. */
export function BackToApp() {
  const t = useTranslations('accounts.nav');
  const next = useSearchParams().get('next');
  // Ringkasan sudah punya tombol utama "Kembali ke app".
  if (usePathname() === '/') return null;
  return (
    <Button href={safeNext(next)} variant="secondary" size="sm" iconLeft="arrow_back">
      <span className="sm:hidden">{t('backShort')}</span>
      <span className="max-sm:hidden">{t('backToApp')}</span>
    </Button>
  );
}
