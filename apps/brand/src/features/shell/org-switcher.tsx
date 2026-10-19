'use client';

import Link from 'next/link';
import { useTranslations } from 'next-intl';
import {
  Avatar,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuLabel,
  DropdownMenuLinkItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  Icon,
  StatusBadge,
} from '@clipper/ui';

export interface SwitcherOrg {
  id: string;
  name: string;
  status: string;
  agency?: boolean;
}

export function OrgSwitcher({ current, orgs }: { current: SwitcherOrg; orgs: SwitcherOrg[] }) {
  const t = useTranslations('brand');
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          aria-label={t('shell.switchOrg', { name: current.name })}
          className="flex min-h-14 w-full items-center gap-3 rounded-card-sm border border-border bg-surface px-3 py-2 text-left shadow-card hover:border-border-hover focus-ring"
        >
          <Avatar name={current.name} size={32} shape="square" />
          <span className="flex min-w-0 flex-1 flex-col gap-0.5">
            <span className="truncate text-body-s font-bold text-ink">{current.name}</span>
            <StatusBadge kind="org" status={current.status} label={t(`orgStatus.${current.status}`)} size="sm" className="self-start" />
          </span>
          <Icon name="unfold_more" size={18} className="text-muted" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-[min(300px,calc(100vw-24px))]">
        <DropdownMenuLabel>{t('shell.orgs')}</DropdownMenuLabel>
        {orgs.map((o) => (
          <DropdownMenuLinkItem
            key={o.id}
            href={`/${o.id}/campaigns`}
            linkAs={Link}
            icon={o.id === current.id ? 'check' : o.agency ? 'groups' : 'storefront'}
            description={o.agency ? t('picker.viaAgency') : t(`orgStatus.${o.status}`)}
          >
            {o.name}
          </DropdownMenuLinkItem>
        ))}
        <DropdownMenuSeparator />
        <DropdownMenuLinkItem href="/new" linkAs={Link} icon="add">
          {t('picker.create')}
        </DropdownMenuLinkItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
