'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useTransition, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { signOut } from '@clipper/auth/actions';
import {
  Avatar, DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger,
  SidebarShell, ThemeToggle, type NavSection,
} from '@clipper/ui';
import { activeHref, navFor } from './nav';

const SECTIONS = ['main', 'campaign', 'trust', 'money', 'platform'] as const;

export function AdminShell({ email, roles, children }: { email: string; roles: string[]; children: ReactNode }) {
  const t = useTranslations('admin');
  const pathname = usePathname();
  const items = navFor(roles);
  const active = activeHref(pathname, items.map((i) => i.href));
  const nav: NavSection[] = SECTIONS.map((s) => ({
    title: s === 'main' ? undefined : t(`nav.section.${s}`),
    items: items
      .filter((i) => i.section === s)
      .map((i) => ({ href: i.href, label: t(`nav.${i.key}`), icon: i.icon, active: i.href === active })),
  })).filter((s) => s.items.length > 0);

  return (
    <SidebarShell
      nav={nav}
      product="Admin"
      linkAs={Link}
      labels={{ openMenu: t('shell.openMenu'), closeMenu: t('shell.closeMenu'), nav: t('shell.nav') }}
      headerActions={<ThemeToggle labels={{ light: t('shell.themeLight'), dark: t('shell.themeDark'), system: t('shell.themeSystem'), toggle: t('shell.theme') }} />}
      userMenu={<UserMenu email={email} roles={roles} />}
    >
      {children}
    </SidebarShell>
  );
}

function UserMenu({ email, roles }: { email: string; roles: string[] }) {
  const t = useTranslations('admin');
  const [pending, start] = useTransition();
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button type="button" className="touch-target rounded-full focus-ring" aria-label={t('shell.account')}>
          <Avatar name={email || 'Admin'} size={36} />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent className="min-w-64">
        <DropdownMenuLabel className="normal-case tracking-normal">
          <span className="block max-w-64 truncate text-sm font-semibold text-ink">{email}</span>
          <span className="block text-caption text-muted">{roles.map((r) => t(`roles.${r}`)).join(' · ')}</span>
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        <DropdownMenuItem icon="logout" tone="danger" disabled={pending} onSelect={() => start(() => signOut('admin'))}>
          {t('shell.signOut')}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
