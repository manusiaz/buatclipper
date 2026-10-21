'use client';

import { useTransition } from 'react';
import Link from 'next/link';
import { useTranslations } from 'next-intl';
import { hosts } from '@clipper/auth';
import { signOut } from '@clipper/auth/actions';
import { deletePush } from '@/features/settings/actions';
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
import type { ChromeData } from './chrome';

export function AccountMenu({ data, pathname }: { data: ChromeData; pathname: string }) {
  const t = useTranslations('clipper.menu');
  const [pending, start] = useTransition();
  const accountsHref = `${hosts.accounts}/?next=${encodeURIComponent(`${hosts.app}${pathname}`)}`;

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          aria-label={t('open')}
          className="touch-target relative grid size-10 place-items-center rounded-full focus-ring"
        >
          <Avatar name={data.name || '?'} src={data.avatar} size={32} />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent className="w-64">
        <DropdownMenuLabel className="flex flex-col gap-0.5 normal-case tracking-normal">
          <span className="truncate text-body-s font-bold text-ink">{data.name}</span>
          {data.username ? <span className="truncate text-caption text-muted">@{data.username}</span> : null}
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        <DropdownMenuLinkItem href="/profile" linkAs={Link} icon="workspace_premium">
          {t('profile')}
        </DropdownMenuLinkItem>
        <DropdownMenuLinkItem href="/leaderboard" linkAs={Link} icon="leaderboard">
          {t('leaderboard')}
        </DropdownMenuLinkItem>
        <DropdownMenuLinkItem href="/referral" linkAs={Link} icon="group_add">
          {t('referral')}
        </DropdownMenuLinkItem>
        <DropdownMenuLinkItem href="/settings" linkAs={Link} icon="settings">
          {t('settings')}
        </DropdownMenuLinkItem>
        {data.community.length || data.aiClip ? <DropdownMenuSeparator /> : null}
        {data.community.map((c) => (
          <DropdownMenuLinkItem key={c.key} href={c.href} external icon="forum">
            {t.has(`community.${c.key}`) ? t(`community.${c.key}`) : t('community.other', { name: c.key })}
          </DropdownMenuLinkItem>
        ))}
        {data.aiClip ? (
          <DropdownMenuLinkItem href={data.aiClip} external icon="movie_edit" description={t('aiClipHint')}>
            {t('aiClip')}
          </DropdownMenuLinkItem>
        ) : null}
        <DropdownMenuSeparator />
        <DropdownMenuLinkItem href={accountsHref} icon="manage_accounts">
          {t('account')}
        </DropdownMenuLinkItem>
        <DropdownMenuItem
          icon="logout"
          tone="danger"
          disabled={pending}
          onSelect={(e) => {
            e.preventDefault();
            start(async () => {
              // Lepas web push perangkat ini selagi masih login (RLS): browser bersama tidak menerima notifikasi akun lama.
              const sub = await navigator.serviceWorker
                ?.getRegistration()
                .then((r) => r?.pushManager.getSubscription())
                .catch(() => null);
              if (sub) await deletePush(sub.endpoint).then(() => sub.unsubscribe()).catch(() => {});
              await signOut('sso');
            });
          }}
        >
          {t('signOut')}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
