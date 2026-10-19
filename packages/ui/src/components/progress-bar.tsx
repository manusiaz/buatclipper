import type { ReactNode } from 'react';
import { cn } from '../lib/cn';

export interface ProgressBarProps {
  /** 0–100. Omit for indeterminate. */
  value?: number;
  max?: number;
  /** Accessible label, e.g. "Budget terpakai". */
  label: string;
  /** Visible label row above the bar. */
  showLabel?: boolean;
  /** Right side of the label row (default: percent). */
  valueLabel?: ReactNode;
  tone?: 'primary' | 'success' | 'warn' | 'danger' | 'paid' | 'auto';
  size?: 'sm' | 'md' | 'lg';
  className?: string;
}

const FILL = {
  primary: '[background:var(--progress-fill)]',
  success: 'bg-success',
  warn: 'bg-warn',
  danger: 'bg-danger',
  paid: 'bg-paid',
} as const;

/** Progress bar (DS 09 card budget bar: 6 px, pill, blue gradient; `auto` turns red ≥ 90 %). */
export function ProgressBar({ value, max = 100, label, showLabel, valueLabel, tone = 'primary', size = 'md', className }: ProgressBarProps) {
  const pct = value === undefined ? undefined : Math.min(100, Math.max(0, (value / max) * 100));
  const resolved = tone === 'auto' ? (pct !== undefined && pct >= 90 ? 'danger' : 'primary') : tone;
  return (
    <div className={cn('flex w-full flex-col gap-1.5', className)}>
      {showLabel ? (
        <div className="flex items-baseline justify-between gap-2 text-caption">
          <span className="font-semibold text-text-2">{label}</span>
          <span className="font-bold text-ink tnum">{valueLabel ?? (pct !== undefined ? `${Math.round(pct)}%` : null)}</span>
        </div>
      ) : null}
      <div
        role="progressbar"
        aria-label={label}
        aria-valuemin={0}
        aria-valuemax={max}
        aria-valuenow={value}
        aria-valuetext={pct !== undefined ? `${Math.round(pct)}%` : undefined}
        className={cn('relative w-full overflow-hidden rounded-full bg-subtle', size === 'sm' ? 'h-1' : size === 'lg' ? 'h-2.5' : 'h-1.5')}
      >
        {pct === undefined ? (
          <div className={cn('absolute inset-y-0 w-2/5 rounded-full animate-indeterminate', FILL[resolved])} data-motion="essential" />
        ) : (
          <div className={cn('h-full rounded-full transition-[width] duration-500 ease-out', FILL[resolved])} style={{ width: `${pct}%` }} />
        )}
      </div>
    </div>
  );
}
