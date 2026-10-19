'use client';

import { useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { RadioGroup, toast } from '@clipper/ui';
import type { Locale } from '@clipper/i18n';
import { setLocale } from './actions';

export function LanguageSwitch() {
  const t = useTranslations('clipper.settings');
  const locale = useLocale();
  const [pending, start] = useTransition();
  return (
    <div aria-busy={pending}>
      <RadioGroup
        name="locale"
        legend={t('language')}
        legendVisible
        orientation="horizontal"
        variant="card"
        value={locale}
        disabled={pending}
        onValueChange={(v) =>
          start(async () => {
            const r = await setLocale(v as Locale);
            if (!r.ok) toast.error(r.message);
          })
        }
        options={[
          { value: 'id', label: 'Bahasa Indonesia' },
          { value: 'en', label: 'English' },
        ]}
      />
    </div>
  );
}
