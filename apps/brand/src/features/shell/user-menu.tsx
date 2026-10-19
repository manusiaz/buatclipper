'use client';

import { usePathname } from 'next/navigation';
import { useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { hosts } from '@clipper/auth';
import { signOut } from '@clipper/auth/actions';
import {
  Avatar,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuLinkItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@clipper/ui';

export function UserMenu({ name, email }: { name: string; email?: string }) {
  const t = useTranslations('brand.shell');
  const path = usePathname();
  const [pending, start] = useTransition();
  const next = encodeURIComponent(`${hosts.brand}${path}`);
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button type="button" aria-label={t('userMenu')} className="inline-flex size-11 items-center justify-center rounded-full focus-ring">
          <Avatar name={name} size={36} />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent>
        <DropdownMenuLabel className="normal-case tracking-normal">
          <span className="block truncate text-body-s font-semibold text-ink">{name}</span>
          {email ? <span className="block truncate text-caption font-normal text-muted">{email}</span> : null}
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        <DropdownMenuLinkItem href={`${hosts.accounts}/?next=${next}`} icon="manage_accounts" description={t('accountHint')}>
          {t('account')}
        </DropdownMenuLinkItem>
        <DropdownMenuLinkItem href="/" icon="storefront">
          {t('allOrgs')}
        </DropdownMenuLinkItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem icon="logout" tone="danger" disabled={pending} onSelect={() => start(() => signOut('sso'))}>
          {t('signOut')}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
