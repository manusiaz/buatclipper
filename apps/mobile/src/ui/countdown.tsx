// Hitung mundur claim 48 jam (format sama dengan <Countdown> web: "47 j 12 m").
import { useEffect, useState } from 'react';
import { useLocale, useTranslations } from 'use-intl';
import { durationParts } from '@clipper/ui/format';
import { Txt } from './core';

export function Countdown({ target, tone }: { target: string; tone?: 'muted' | 'text2' }) {
  const t = useTranslations('clipper.claim');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(id);
  }, []);
  const ms = new Date(target).getTime() - now;
  if (ms <= 0) return <Txt variant="caption" weight="700" tone={tone}>{t('expired')}</Txt>;
  const p = durationParts(ms);
  return <Txt variant="caption" weight="700" tone={tone}>{`${p.totalHours} ${locale === 'en' ? 'h' : 'j'} ${String(p.minutes).padStart(2, '0')} m`}</Txt>;
}
