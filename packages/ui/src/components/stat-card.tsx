import type { ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Card } from './card';
import { Icon, type IconName } from './icon';

export interface StatDelta {
  /** Display text, e.g. "18%" or "+4". */
  value: string;
  trend: 'up' | 'down' | 'flat';
  /** Whether this direction is good (colours green). Default: up = good. */
  positive?: boolean;
  /** Context, e.g. "vs minggu lalu". */
  caption?: ReactNode;
}

export interface StatCardProps {
  label: ReactNode;
  value: ReactNode;
  delta?: StatDelta;
  icon?: IconName;
  /** Small helper under the value. */
  hint?: ReactNode;
  /** `dark` = DS highlight KPI (first card), `blue` for promos. */
  variant?: 'default' | 'dark' | 'blue' | 'tint';
  /** Mini bar sparkline (0–100 values, last bar highlighted). */
  spark?: number[];
  footer?: ReactNode;
  className?: string;
}

/** KPI tile (DS 11 §3): label, big tabular value, delta chip, optional sparkline. Server-compatible. */
export function StatCard({ label, value, delta, icon, hint, variant = 'default', spark, footer, className }: StatCardProps) {
  const onDark = variant === 'dark' || variant === 'blue';
  const good = delta ? (delta.trend === 'flat' ? undefined : (delta.positive ?? true) === (delta.trend === 'up')) : undefined;
  return (
    <Card variant={variant} padding="none" className={cn('flex flex-col gap-3 p-4 md:p-5', className)}>
      <div className="flex items-start justify-between gap-3">
        <p className={cn('text-body-s font-semibold', onDark ? 'text-white/75' : 'text-muted')}>{label}</p>
        {icon ? (
          <span
            className={cn(
              'grid size-9 shrink-0 place-items-center rounded-[11px]',
              onDark ? 'bg-white/12 text-white' : 'bg-primary-soft text-primary-soft-fg',
            )}
          >
            <Icon name={icon} size={20} filled />
          </span>
        ) : null}
      </div>
      <div className="flex items-end justify-between gap-3">
        <div className="flex min-w-0 flex-col gap-1.5">
          <p className="truncate text-numeric tnum">{value}</p>
          {delta ? (
            <p className="flex flex-wrap items-center gap-1.5 text-caption">
              <span
                className={cn(
                  'inline-flex h-5 items-center gap-0.5 rounded-full px-1.5 font-bold tnum',
                  good === true && 'bg-success-bg text-success-fg',
                  good === false && 'bg-danger-bg text-danger-fg',
                  good === undefined && 'bg-subtle text-text-2',
                )}
              >
                {delta.trend !== 'flat' ? <Icon name={delta.trend === 'up' ? 'arrow_upward' : 'arrow_downward'} size={12} /> : null}
                {delta.value}
              </span>
              {delta.caption ? <span className={onDark ? 'text-white/70' : 'text-muted'}>{delta.caption}</span> : null}
            </p>
          ) : null}
          {hint ? <p className={cn('text-caption', onDark ? 'text-white/70' : 'text-muted')}>{hint}</p> : null}
        </div>
        {spark && spark.length ? (
          <div aria-hidden className="flex h-10 shrink-0 items-end gap-[3px]">
            {spark.map((v, i) => (
              <span
                key={i}
                className={cn(
                  'w-[5px] rounded-full',
                  i === spark.length - 1 ? (onDark ? 'bg-brand-400' : 'bg-primary') : onDark ? 'bg-white/18' : 'bg-brand-200 dark:bg-primary-soft-hover',
                )}
                style={{ height: `${Math.max(8, Math.min(100, v))}%` }}
              />
            ))}
          </div>
        ) : null}
      </div>
      {footer ? <div className={cn('border-t pt-3 text-caption', onDark ? 'border-white/12' : 'border-border')}>{footer}</div> : null}
    </Card>
  );
}
