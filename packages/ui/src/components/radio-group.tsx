import { useId, type ChangeEvent, type ReactNode } from 'react';
import { cn } from '../lib/cn';

export interface RadioOption {
  value: string;
  label: ReactNode;
  description?: ReactNode;
  disabled?: boolean;
  /** Extra content on the right (card variant), e.g. a price. */
  aside?: ReactNode;
}

export interface RadioGroupProps {
  name: string;
  options: RadioOption[];
  value?: string;
  defaultValue?: string;
  /** Client-side change handler (use inside client components). */
  onValueChange?: (value: string) => void;
  /** Accessible group name (rendered as visually-hidden legend unless `legendVisible`). */
  legend: ReactNode;
  legendVisible?: boolean;
  orientation?: 'vertical' | 'horizontal';
  /** `card` = bordered selectable cards (DS 09 "Card outline — radio card"). */
  variant?: 'default' | 'card';
  required?: boolean;
  disabled?: boolean;
  invalid?: boolean;
  'aria-describedby'?: string;
  className?: string;
}

const radioClasses = cn(
  'peer touch-target size-[22px] shrink-0 cursor-pointer appearance-none rounded-full border-[1.5px] border-border-hover bg-surface',
  'transition-[border-color,background-color,box-shadow] duration-120 ease-out',
  'hover:border-primary hover:bg-brand-50 dark:hover:bg-primary-soft focus-ring',
  'checked:border-2 checked:border-primary checked:bg-[radial-gradient(circle,var(--color-primary)_0_4.5px,transparent_5px)] checked:hover:bg-surface checked:hover:bg-[radial-gradient(circle,var(--color-primary)_0_4.5px,transparent_5px)]',
  'disabled:cursor-not-allowed disabled:opacity-40',
);

/** Native radio group styled per DS (works without JS; server-compatible). */
export function RadioGroup({
  name,
  options,
  value,
  defaultValue,
  onValueChange,
  legend,
  legendVisible,
  orientation = 'vertical',
  variant = 'default',
  required,
  disabled,
  invalid,
  className,
  ...aria
}: RadioGroupProps) {
  const id = useId();
  const onChange = onValueChange ? (e: ChangeEvent<HTMLInputElement>) => onValueChange(e.target.value) : undefined;
  return (
    <fieldset
      role="radiogroup"
      aria-describedby={aria['aria-describedby']}
      aria-invalid={invalid || undefined}
      aria-required={required || undefined}
      disabled={disabled}
      className={cn('min-w-0', className)}
    >
      <legend className={legendVisible ? 'mb-2 text-label text-ink' : 'sr-only'}>{legend}</legend>
      <div className={cn('flex gap-3', orientation === 'vertical' ? 'flex-col' : 'flex-row flex-wrap', variant === 'card' && 'gap-2.5')}>
        {options.map((o, i) => {
          const optId = `${id}-${i}`;
          const descId = o.description ? `${optId}-d` : undefined;
          const input = (
            <input
              id={optId}
              type="radio"
              name={name}
              value={o.value}
              checked={value !== undefined ? value === o.value : undefined}
              defaultChecked={value === undefined && defaultValue !== undefined ? defaultValue === o.value : undefined}
              onChange={onChange}
              readOnly={value !== undefined && !onChange ? true : undefined}
              disabled={o.disabled}
              required={required}
              aria-describedby={descId}
              className={cn(radioClasses, invalid && 'border-danger')}
            />
          );
          if (variant === 'card') {
            return (
              <label
                key={o.value}
                htmlFor={optId}
                className={cn(
                  'flex cursor-pointer items-start gap-3 rounded-card-sm border-[1.5px] border-border-strong bg-surface p-4 transition-[border-color,background-color,box-shadow] duration-120',
                  'hover:border-border-hover has-[:checked]:border-primary has-[:checked]:bg-brand-50 dark:has-[:checked]:bg-primary-soft',
                  'has-[:focus-visible]:shadow-[0_0_0_4px_var(--color-focus-halo)] has-[:disabled]:cursor-not-allowed has-[:disabled]:opacity-50',
                  orientation === 'horizontal' && 'flex-1',
                )}
              >
                <span className="flex h-6 items-center">{input}</span>
                <span className="flex min-w-0 flex-1 flex-col">
                  <span className="text-sm leading-6 font-bold text-ink">{o.label}</span>
                  {o.description ? (
                    <span id={descId} className="text-caption text-muted">
                      {o.description}
                    </span>
                  ) : null}
                </span>
                {o.aside ? <span className="text-sm font-bold text-ink tnum">{o.aside}</span> : null}
              </label>
            );
          }
          return (
            <div key={o.value} className="flex items-start gap-3">
              <span className="flex h-6 items-center">{input}</span>
              <span className="flex min-w-0 flex-col">
                <label htmlFor={optId} className="cursor-pointer text-sm leading-6 font-semibold text-ink peer-disabled:cursor-not-allowed">
                  {o.label}
                </label>
                {o.description ? (
                  <span id={descId} className="text-caption text-muted">
                    {o.description}
                  </span>
                ) : null}
              </span>
            </div>
          );
        })}
      </div>
    </fieldset>
  );
}
