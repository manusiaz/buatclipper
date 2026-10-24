'use client';

import { useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { locales } from '@clipper/i18n';
import { cn } from '@clipper/ui';
import { setLocale } from './actions';

export function LocaleSwitch() {
  const t = useTranslations('common');
  const current = useLocale();
  const router = useRouter();
  const [pending, start] = useTransition();
  return (
    <div role="group" aria-label={t('language')} className="flex items-center rounded-chip border border-border p-0.5">
      {locales.map((l) => (
        <button
          key={l}
          type="button"
          aria-pressed={l === current}
          disabled={pending}
          onClick={() => start(async () => (await setLocale(l), router.refresh()))}
          className={cn(
            'focus-ring rounded-chip px-2 py-1 text-caption font-bold uppercase',
            l === current ? 'bg-primary-soft text-primary-soft-fg' : 'text-muted hover:text-ink',
          )}
        >
          {l}
        </button>
      ))}
    </div>
  );
}
