'use client';

import { useEffect, useState } from 'react';
import { cn } from '../lib/cn';
import { formatDateTime, formatRelative, type UiLocale } from '../lib/format';

export interface RelativeTimeProps {
  /** ISO string, Date or epoch ms. */
  value: string | Date | number;
  locale?: UiLocale;
  /** Re-render interval in ms. Default 60 000. */
  refreshMs?: number;
  /** Show absolute time instead of relative before hydration (no flash of a wrong "x jam lalu"). Default false. */
  absoluteFirst?: boolean;
  className?: string;
}

/**
 * "12 hari lagi" / "3 jam lalu" — hydration-safe: the server string may differ by a minute, so the <time>
 * suppresses the mismatch warning and the client recomputes after mount. Full date in `title` + dateTime attr.
 */
export function RelativeTime({ value, locale = 'id', refreshMs = 60_000, absoluteFirst = false, className }: RelativeTimeProps) {
  const [now, setNow] = useState<number | null>(null);
  useEffect(() => {
    setNow(Date.now());
    const t = setInterval(() => setNow(Date.now()), refreshMs);
    return () => clearInterval(t);
  }, [refreshMs]);
  const date = new Date(value);
  const absolute = formatDateTime(date, locale);
  const text = now === null && absoluteFirst ? absolute : formatRelative(date, now ?? Date.now(), locale);
  return (
    <time dateTime={date.toISOString()} title={absolute} suppressHydrationWarning className={cn('tnum', className)}>
      {text}
    </time>
  );
}
