import type { ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Icon } from './icon';

export interface StepperStep {
  label: ReactNode;
  description?: ReactNode;
  /** Mark a completed step as having an error (e.g. validation failed). */
  error?: boolean;
}

export interface StepperProps {
  steps: StepperStep[];
  /** 0-based index of the current step. Steps before it are complete. */
  current: number;
  /** Optional navigation to a completed step (wizard "edit"). Client parent only. */
  onStepClick?: (index: number) => void;
  /** Mobile progress text, default "Langkah {n} dari {total}". */
  progressLabel?: (n: number, total: number) => string;
  label?: string;
  className?: string;
}

/**
 * Wizard stepper (7-step campaign builder). Desktop (≥ md): horizontal numbered steps with connectors.
 * Mobile: compact "Langkah 3 dari 7" + current label + segmented bar. Server-compatible.
 */
export function Stepper({ steps, current, onStepClick, progressLabel, label = 'Langkah', className }: StepperProps) {
  const total = steps.length;
  const cur = steps[current];
  const text = progressLabel ? progressLabel(current + 1, total) : `Langkah ${current + 1} dari ${total}`;
  return (
    <nav aria-label={label} className={cn('w-full', className)}>
      {/* compact (mobile) */}
      <div className="flex flex-col gap-2 md:hidden">
        <div className="flex items-baseline justify-between gap-3">
          <p className="text-h6 text-ink">{cur?.label}</p>
          <p className="shrink-0 text-caption font-semibold text-muted tnum">{text}</p>
        </div>
        <div className="flex gap-1" aria-hidden>
          {steps.map((s, i) => (
            <span
              key={i}
              className={cn('h-1.5 flex-1 rounded-full', s.error ? 'bg-danger' : i < current ? 'bg-primary' : i === current ? 'bg-cta' : 'bg-subtle')}
            />
          ))}
        </div>
      </div>
      {/* full (desktop) */}
      <ol className="hidden items-start md:flex">
        {steps.map((s, i) => {
          const done = i < current;
          const active = i === current;
          const state = s.error ? 'error' : done ? 'done' : active ? 'active' : 'todo';
          const clickable = !!onStepClick && done;
          const bubble = (
            <span
              className={cn(
                'grid size-8 shrink-0 place-items-center rounded-full text-sm font-extrabold tnum transition-colors duration-160',
                state === 'done' && 'bg-primary text-white',
                state === 'active' && 'bg-cta text-white shadow-[0_6px_14px_-6px_rgb(29_91_255/0.7)] ring-4 ring-primary-soft',
                state === 'todo' && 'border-[1.5px] border-border-strong bg-surface text-muted',
                state === 'error' && 'bg-danger text-white',
              )}
            >
              {state === 'done' ? <Icon name="check" size={18} /> : state === 'error' ? <Icon name="error" size={18} filled /> : i + 1}
            </span>
          );
          const textBlock = (
            <span className="flex min-w-0 flex-col items-center gap-0.5 text-center">
              <span className={cn('text-caption font-bold', active ? 'text-ink' : done ? 'text-text-2' : 'text-muted')}>{s.label}</span>
              {s.description ? <span className="text-[11px] text-muted">{s.description}</span> : null}
            </span>
          );
          return (
            <li key={i} className="relative flex flex-1 flex-col items-center gap-2" aria-current={active ? 'step' : undefined}>
              {i > 0 ? (
                <span aria-hidden className={cn('absolute top-4 right-[calc(50%+22px)] left-[calc(-50%+22px)] h-0.5 rounded-full', i <= current ? 'bg-primary' : 'bg-border')} />
              ) : null}
              {clickable ? (
                <button type="button" onClick={() => onStepClick?.(i)} className="flex flex-col items-center gap-2 rounded-chip focus-ring">
                  {bubble}
                  {textBlock}
                </button>
              ) : (
                <>
                  {bubble}
                  {textBlock}
                </>
              )}
              <span className="sr-only">{state === 'done' ? '(selesai)' : state === 'active' ? '(sekarang)' : state === 'error' ? '(perlu diperbaiki)' : ''}</span>
            </li>
          );
        })}
      </ol>
    </nav>
  );
}
