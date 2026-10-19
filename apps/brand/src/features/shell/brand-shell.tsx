'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import type { ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { Logo, SidebarShell, type IconName, type NavItem } from '@clipper/ui';

export interface ShellNavItem {
  href: string;
  label: string;
  icon: IconName;
  badge?: number;
}

/** SidebarShell + item aktif dari URL (layout tidak dirender ulang saat pindah halaman). */
export function BrandShell({
  nav,
  orgSwitcher,
  userMenu,
  headerActions,
  banner,
  footer,
  children,
}: {
  nav: ShellNavItem[];
  orgSwitcher?: ReactNode;
  userMenu: ReactNode;
  headerActions?: ReactNode;
  banner?: ReactNode;
  footer?: ReactNode;
  children: ReactNode;
}) {
  const t = useTranslations('brand.shell');
  const path = usePathname();
  const items: NavItem[] = nav.map((n) => ({ ...n, badge: n.badge || undefined, active: path === n.href || path.startsWith(`${n.href}/`) }));
  return (
    <SidebarShell
      nav={items}
      logo={<Logo size={28} product={t('product')} href="/" linkAs={Link} />}
      orgSwitcher={orgSwitcher}
      userMenu={userMenu}
      headerActions={headerActions}
      banner={banner}
      sidebarFooter={footer}
      linkAs={Link}
      labels={{ openMenu: t('openMenu'), closeMenu: t('closeMenu'), nav: t('nav') }}
    >
      {children}
    </SidebarShell>
  );
}
