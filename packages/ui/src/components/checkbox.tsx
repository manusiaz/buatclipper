'use client';

import * as CheckboxPrimitive from '@radix-ui/react-checkbox';
import { useId, type ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Icon } from './icon';

export interface CheckboxProps {
  checked?: boolean | 'indeterminate';
  defaultChecked?: boolean | 'indeterminate';
  onCheckedChange?: (checked: boolean | 'indeterminate') => void;
  /** Visible label (clickable). Omit only when an external label/aria-label is provided. */
  label?: ReactNode;
  description?: ReactNode;
  id?: string;
  name?: string;
  value?: string;
  disabled?: boolean;
  required?: boolean;
  invalid?: boolean;
  'aria-label'?: string;
  'aria-describedby'?: string;
  className?: string;
}

/** 22 px checkbox: blue gradient when checked, indeterminate dash, DS focus ring (DS 08 §3). */
export function Checkbox({
  checked,
  defaultChecked,
  onCheckedChange,
  label,
  description,
  id: idProp,
  name,
  value,
  disabled,
  required,
  invalid,
  className,
  ...aria
}: CheckboxProps) {
  const auto = useId();
  const id = idProp ?? auto;
  const descId = description ? `${id}-desc` : undefined;
  const box = (
    <CheckboxPrimitive.Root
      id={id}
      checked={checked}
      defaultChecked={defaultChecked}
      onCheckedChange={onCheckedChange}
      name={name}
      value={value}
      disabled={disabled}
      required={required}
      aria-invalid={invalid || undefined}
      aria-label={aria['aria-label']}
      aria-describedby={[aria['aria-describedby'], descId].filter(Boolean).join(' ') || undefined}
      className={cn(
        'peer touch-target grid size-[22px] shrink-0 place-items-center rounded-[7px] border-[1.5px] border-border-hover bg-surface text-white',
        'transition-[background-color,border-color,box-shadow] duration-120 ease-out',
        'hover:border-primary hover:bg-brand-50 dark:hover:bg-primary-soft focus-ring',
        'data-[state=checked]:border-0 data-[state=checked]:bg-cta data-[state=checked]:shadow-[0_4px_10px_-4px_rgb(29_91_255/0.6)]',
        'data-[state=indeterminate]:border-0 data-[state=indeterminate]:bg-cta',
        'disabled:cursor-not-allowed disabled:opacity-40',
        invalid && 'border-danger',
        !label && className,
      )}
    >
      <CheckboxPrimitive.Indicator className="grid place-items-center data-[state=open]:animate-pop-in">
        {checked === 'indeterminate' ? <Icon name="remove" size={18} /> : <Icon name="check" size={18} />}
      </CheckboxPrimitive.Indicator>
    </CheckboxPrimitive.Root>
  );
  if (!label) return box;
  return (
    <div className={cn('flex items-start gap-3', className)}>
      <div className="flex h-6 items-center">{box}</div>
      <div className="flex min-w-0 flex-col">
        <label htmlFor={id} className={cn('cursor-pointer text-sm leading-6 font-semibold text-ink', disabled && 'cursor-not-allowed text-disabled-fg')}>
          {label}
          {required ? <span aria-hidden className="ml-0.5 text-danger">*</span> : null}
        </label>
        {description ? (
          <span id={descId} className="text-caption text-muted">
            {description}
          </span>
        ) : null}
      </div>
    </div>
  );
}
