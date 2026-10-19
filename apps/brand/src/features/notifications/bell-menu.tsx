'use client';

import Link from 'next/link';
import { useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { Button, EmptyState, IconButton, Popover, PopoverClose, PopoverContent, PopoverTrigger, RelativeTime, cn } from '@clipper/ui';
import { markNotificationsRead } from './actions';

export interface BellItem {
  id: number;
  text: string;
  href: string | null;
  createdAt: string;
  unread: boolean;
}

export function BellMenu({ items, unread }: { items: BellItem[]; unread: number }) {
  const t = useTranslations('brand.bell');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [pending, start] = useTransition();
  const read = (id?: number) => start(() => markNotificationsRead(id));

  return (
    <Popover>
      <PopoverTrigger asChild>
        <IconButton icon="notifications" label={unread ? t('labelUnread', { count: unread }) : t('label')} badge={unread || undefined} />
      </PopoverTrigger>
      <PopoverContent align="end" className="w-[min(380px,calc(100vw-24px))] p-0">
        <div className="flex items-center justify-between gap-2 border-b border-border px-4 py-3">
          <p className="text-h6 text-ink">{t('title')}</p>
          {unread > 0 ? (
            <Button variant="link" size="sm" loading={pending} onClick={() => read()}>
              {t('markAll')}
            </Button>
          ) : null}
        </div>
        {items.length === 0 ? (
          <EmptyState compact icon="notifications" title={t('empty')} className="py-8" />
        ) : (
          <ul className="max-h-[min(420px,70dvh)] overflow-y-auto p-1.5">
            {items.map((n) => {
              const body = (
                <>
                  <span aria-hidden className={cn('mt-1.5 size-2 shrink-0 rounded-full', n.unread ? 'bg-primary' : 'bg-transparent')} />
                  <span className="flex min-w-0 flex-col gap-0.5">
                    <span className={cn('text-body-s break-words', n.unread ? 'font-semibold text-ink' : 'text-text-2')}>{n.text}</span>
                    {n.createdAt ? <RelativeTime value={n.createdAt} locale={locale} className="text-caption text-muted" /> : null}
                  </span>
                </>
              );
              const cls = 'flex min-h-11 w-full gap-3 rounded-[10px] px-3 py-2.5 text-left hover:bg-subtle focus-ring';
              return (
                <li key={n.id}>
                  {n.href ? (
                    <PopoverClose asChild>
                      <Link href={n.href} className={cls} onClick={() => n.unread && read(n.id)}>
                        {body}
                      </Link>
                    </PopoverClose>
                  ) : (
                    <div className={cls}>{body}</div>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </PopoverContent>
    </Popover>
  );
}
