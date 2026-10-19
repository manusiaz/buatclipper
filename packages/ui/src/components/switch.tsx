'use client';

import * as SwitchPrimitive from '@radix-ui/react-switch';
import { useId, type ReactNode } from 'react';
import { cn } from '../lib/cn';

export interface SwitchProps {
  checked?: boolean;
  defaultChecked?: boolean;
  onCheckedChange?: (checked: boolean) => void;
  label?: ReactNode;
  description?: ReactNode;
  /** Label on the left, switch on the right (settings rows). Default true when a label is given. */
  labelFirst?: boolean;
  id?: string;
  name?: string;
  value?: string;
  disabled?: boolean;
  required?: boolean;
  'aria-label'?: string;
  'aria-describedby'?: string;
  className?: string;
}

/** 44×26 toggle (DS 08 §3): grey off, blue on, white thumb with shadow. */
export function Switch({
  checked,
  defaultChecked,
  onCheckedChange,
  label,
  description,
  labelFirst = true,
  id: idProp,
  name,
  value,
  disabled,
  required,
  className,
  ...aria
}: SwitchProps) {
  const auto = useId();
  const id = idProp ?? auto;
  const descId = description ? `${id}-desc` : undefined;
  const control = (
    <SwitchPrimitive.Root
      id={id}
      checked={checked}
      defaultChecked={defaultChecked}
      onCheckedChange={onCheckedChange}
      name={name}
      value={value}
      disabled={disabled}
      required={required}
      aria-label={aria['aria-label']}
      aria-describedby={[aria['aria-describedby'], descId].filter(Boolean).join(' ') || undefined}
      className={cn(
        'group touch-target relative inline-flex h-[26px] w-11 shrink-0 cursor-pointer items-center rounded-full px-[3px]',
        'bg-border-strong shadow-[inset_0_1px_3px_rgb(10_18_38/0.2)] transition-colors duration-160 ease-out',
        'hover:bg-border-hover data-[state=checked]:bg-primary data-[state=checked]:hover:bg-primary-hover focus-ring',
        'disabled:cursor-not-allowed disabled:opacity-40',
        !label && className,
      )}
    >
      <SwitchPrimitive.Thumb
        className={cn(
          'block size-5 rounded-full bg-white shadow-[0_2px_5px_rgb(10_18_38/0.3)]',
          'transition-transform duration-160 ease-out data-[state=checked]:translate-x-[18px]',
        )}
      />
    </SwitchPrimitive.Root>
  );
  if (!label) return control;
  return (
    <div className={cn('flex items-start gap-3', labelFirst && 'justify-between', className)}>
      {!labelFirst ? <div className="flex h-6 items-center">{control}</div> : null}
      <div className="flex min-w-0 flex-col">
        <label htmlFor={id} className={cn('cursor-pointer text-sm leading-6 font-semibold text-ink', disabled && 'cursor-not-allowed text-disabled-fg')}>
          {label}
        </label>
        {description ? (
          <span id={descId} className="text-caption text-muted">
            {description}
          </span>
        ) : null}
      </div>
      {labelFirst ? <div className="flex h-6 items-center">{control}</div> : null}
    </div>
  );
}
