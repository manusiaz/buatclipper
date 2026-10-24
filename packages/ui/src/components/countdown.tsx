'use client';

import { useEffect, useState } from 'react';
import { cn } from '../lib/cn';
import { durationParts, type UiLocale } from '../lib/format';
import { Icon } from './icon';

export interface CountdownProps {
  /** Target moment (ISO). */
  target: string | Date | number;
  locale?: UiLocale;
  /** Show seconds (default false → updates every 30 s). */
  showSeconds?: boolean;
  /** Text when the target has passed. Default "Waktu habis" / "Time's up". */
  expiredLabel?: string;
  /** Hours left at which the countdown turns warn (default 6) and danger (default 1). */
  warnAtHours?: number;
  dangerAtHours?: number;
  /** Leading timer icon. */
  withIcon?: boolean;
  onExpire?: () => void;
  className?: string;
}

/**
 * Countdown "47 j 12 m" (claim window, payout hold). Hours are total hours (48 j, not 2 h 0 j) as in the PRD.
 * Renders a stable placeholder width on the server and ticks on the client.
 */
export function Countdown({
  target,
  locale = 'id',
  showSeconds = false,
  expiredLabel,
  warnAtHours = 6,
  dangerAtHours = 1,
  withIcon = false,
  onExpire,
  className,
}: CountdownProps) {
  const end = new Date(target).getTime();
  const [now, setNow] = useState<number | null>(null);
  useEffect(() => {
    setNow(Date.now());
    const t = setInterval(() => setNow(Date.now()), showSeconds ? 1000 : 30_000);
    return () => clearInterval(t);
  }, [showSeconds]);
  const left = now === null ? null : end - now;
  const expired = left !== null && left <= 0;
  useEffect(() => {
    if (expired) onExpire?.();
  }, [expired, onExpire]);

  const p = durationParts(left ?? 0);
  const h = locale === 'en' ? 'h' : 'j';
  const text =
    left === null
      ? '— ' + h + ' — m'
      : expired
        ? (expiredLabel ?? (locale === 'en' ? "Time's up" : 'Waktu habis'))
        : showSeconds
          ? `${p.totalHours} ${h} ${String(p.minutes).padStart(2, '0')} m ${String(p.seconds).padStart(2, '0')} ${locale === 'en' ? 's' : 'd'}`
          : `${p.totalHours} ${h} ${String(p.minutes).padStart(2, '0')} m`;
  const hoursLeft = (left ?? Infinity) / 3_600_000;
  const tone = expired || hoursLeft <= dangerAtHours ? 'text-danger-fg' : hoursLeft <= warnAtHours ? 'text-warn-fg' : undefined;

  return (
    <span className={cn('inline-flex items-center gap-1 font-bold tnum', tone, className)}>
      {withIcon ? <Icon name="timer" size={16} /> : null}
      <time dateTime={new Date(end).toISOString()} aria-live="off">
        {text}
      </time>
    </span>
  );
}
