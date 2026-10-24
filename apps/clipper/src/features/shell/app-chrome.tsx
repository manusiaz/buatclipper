'use client';

// Shell PWA (§6.8): nav bawah Campaign/Tugas/Wallet/Sosmed, lonceng, menu avatar. Aktif & judul dihitung dari pathname
// karena root layout tidak dirender ulang saat pindah halaman.
import type { ReactNode } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { IconButton, Logo, MobileAppShell, type NavItem } from '@clipper/ui';
import type { ChromeData } from './chrome';
import { AccountMenu } from './account-menu';

const BARE = ['/login', '/offline', '/auth'];

const SUB_PAGES: { match: RegExp; title: string; back?: string }[] = [
  { match: /^\/campaigns\/[^/]+$/, title: 'detail.header', back: '/campaigns' },
  { match: /^\/wallet\/withdraw$/, title: 'withdraw.title', back: '/wallet' },
  { match: /^\/notifications$/, title: 'notifications.title' },
  { match: /^\/profile$/, title: 'profile.title' },
  { match: /^\/leaderboard$/, title: 'leaderboard.title', back: '/profile' },
  { match: /^\/referral$/, title: 'referral.title' },
  { match: /^\/settings$/, title: 'settings.title' },
  { match: /^\/share$/, title: 'share.title', back: '/tasks' },
];

export function AppChrome({ data, children }: { data: ChromeData | null; children: ReactNode }) {
  const pathname = usePathname() ?? '/';
  const t = useTranslations('clipper');
  if (!data || BARE.some((p) => pathname === p || pathname.startsWith(`${p}/`))) return <>{children}</>;

  const is = (href: string) => pathname === href || pathname.startsWith(`${href}/`);
  const nav: NavItem[] = [
    { href: '/campaigns', label: t('nav.campaigns'), icon: 'campaign', active: is('/campaigns') },
    { href: '/tasks', label: t('nav.tasks'), icon: 'checklist', active: is('/tasks') },
    { href: '/wallet', label: t('nav.wallet'), icon: 'account_balance_wallet', active: is('/wallet') },
    { href: '/social', label: t('nav.social'), icon: 'link', active: is('/social'), badge: data.socialAttention },
  ];
  const sub = SUB_PAGES.find((s) => s.match.test(pathname));

  return (
    <MobileAppShell
      linkAs={Link}
      nav={nav}
      navLabel={t('nav.label')}
      logo={<Logo size={28} href="/campaigns" linkAs={Link} />}
      title={sub ? t(sub.title) : undefined}
      back={sub?.back ? { href: sub.back, label: t('nav.back') } : undefined}
      actions={
        <IconButton
          icon="notifications"
          variant="ghost"
          label={t('nav.notifications')}
          badge={data.unread || undefined}
          href="/notifications"
          linkAs={Link}
        />
      }
      avatar={<AccountMenu data={data} pathname={pathname} />}
    >
      {children}
    </MobileAppShell>
  );
}
