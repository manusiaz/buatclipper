'use client';

import * as SelectPrimitive from '@radix-ui/react-select';
import type { ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Icon, type IconName } from './icon';
import { fieldShellClasses } from './input';

export interface SelectOption {
  /** Non-empty string (Radix reserves "" for "no value"). */
  value: string;
  label: ReactNode;
  /** Secondary line under the label. */
  description?: ReactNode;
  icon?: IconName;
  disabled?: boolean;
}

export interface SelectGroup {
  label: ReactNode;
  options: SelectOption[];
}

export interface SelectProps {
  options: Array<SelectOption | SelectGroup>;
  value?: string;
  defaultValue?: string;
  onValueChange?: (value: string) => void;
  placeholder?: ReactNode;
  id?: string;
  name?: string;
  disabled?: boolean;
  required?: boolean;
  invalid?: boolean;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  'aria-label'?: string;
  'aria-describedby'?: string;
  'aria-invalid'?: boolean | 'true' | 'false';
  /** Leading icon inside the trigger. */
  iconLeft?: IconName;
  /** `md` = 48 px (form), `sm` = 40 px (toolbar/filter). */
  inputSize?: 'sm' | 'md';
  className?: string;
  contentClassName?: string;
}

const isGroup = (o: SelectOption | SelectGroup): o is SelectGroup => 'options' in o;

function Item({ option }: { option: SelectOption }) {
  return (
    <SelectPrimitive.Item
      value={option.value}
      disabled={option.disabled}
      className={cn(
        'relative flex min-h-11 cursor-pointer select-none items-center gap-3 rounded-[10px] py-2 pr-9 pl-3 text-sm font-medium text-ink outline-none',
        'data-[highlighted]:bg-subtle data-[state=checked]:bg-primary-soft data-[state=checked]:font-bold data-[state=checked]:text-primary-soft-fg',
        'data-[disabled]:cursor-not-allowed data-[disabled]:text-disabled-fg',
      )}
    >
      {option.icon ? <Icon name={option.icon} size={20} className="text-muted" /> : null}
      <div className="flex min-w-0 flex-col">
        <SelectPrimitive.ItemText>{option.label}</SelectPrimitive.ItemText>
        {option.description ? <span className="text-caption font-normal text-muted">{option.description}</span> : null}
      </div>
      <SelectPrimitive.ItemIndicator className="absolute right-3 inline-flex">
        <Icon name="check" size={18} />
      </SelectPrimitive.ItemIndicator>
    </SelectPrimitive.Item>
  );
}

/** Dropdown select (Radix) styled as a DS field. Keyboard + screen-reader accessible. */
export function Select({
  options,
  value,
  defaultValue,
  onValueChange,
  placeholder = 'Pilih…',
  id,
  name,
  disabled,
  required,
  invalid,
  open,
  onOpenChange,
  iconLeft,
  inputSize = 'md',
  className,
  contentClassName,
  ...aria
}: SelectProps) {
  const isInvalid = invalid ?? (aria['aria-invalid'] === true || aria['aria-invalid'] === 'true');
  return (
    <SelectPrimitive.Root
      value={value}
      defaultValue={defaultValue}
      onValueChange={onValueChange}
      name={name}
      disabled={disabled}
      required={required}
      open={open}
      onOpenChange={onOpenChange}
    >
      <SelectPrimitive.Trigger
        id={id}
        aria-label={aria['aria-label']}
        aria-describedby={aria['aria-describedby']}
        aria-invalid={isInvalid || undefined}
        data-invalid={isInvalid || undefined}
        className={cn(
          fieldShellClasses,
          'cursor-pointer justify-between text-left text-base outline-none',
          'disabled:cursor-not-allowed disabled:border-border disabled:bg-disabled disabled:text-disabled-fg',
          'data-[placeholder]:text-placeholder data-[state=open]:border-focus data-[state=open]:shadow-[0_0_0_4px_var(--color-focus-halo)]',
          inputSize === 'md' ? 'h-12 px-3.5' : 'h-10 px-3 text-sm',
          className,
        )}
      >
        <span className="flex min-w-0 items-center gap-2">
          {iconLeft ? <Icon name={iconLeft} size={20} className="text-muted" /> : null}
          <span className="truncate">
            <SelectPrimitive.Value placeholder={placeholder} />
          </span>
        </span>
        <SelectPrimitive.Icon asChild>
          <Icon name="keyboard_arrow_down" size={20} className="text-muted transition-transform duration-160 group-data-[state=open]/field:rotate-180" />
        </SelectPrimitive.Icon>
      </SelectPrimitive.Trigger>
      <SelectPrimitive.Portal>
        <SelectPrimitive.Content
          position="popper"
          sideOffset={6}
          collisionPadding={12}
          className={cn(
            'z-50 max-h-[min(360px,var(--radix-select-content-available-height))] min-w-[var(--radix-select-trigger-width)] overflow-hidden',
            'rounded-popover border border-border bg-surface text-ink shadow-pop',
            'data-[state=open]:animate-pop-in data-[state=closed]:animate-pop-out',
            contentClassName,
          )}
        >
          <SelectPrimitive.ScrollUpButton className="flex h-7 items-center justify-center text-muted">
            <Icon name="keyboard_arrow_up" size={18} />
          </SelectPrimitive.ScrollUpButton>
          <SelectPrimitive.Viewport className="p-1.5">
            {options.map((o, i) =>
              isGroup(o) ? (
                <SelectPrimitive.Group key={i} className="py-1">
                  <SelectPrimitive.Label className="px-3 pt-1.5 pb-1 text-[11px] font-bold tracking-[0.14em] text-muted uppercase">{o.label}</SelectPrimitive.Label>
                  {o.options.map((opt) => (
                    <Item key={opt.value} option={opt} />
                  ))}
                </SelectPrimitive.Group>
              ) : (
                <Item key={o.value} option={o} />
              ),
            )}
          </SelectPrimitive.Viewport>
          <SelectPrimitive.ScrollDownButton className="flex h-7 items-center justify-center text-muted">
            <Icon name="keyboard_arrow_down" size={18} />
          </SelectPrimitive.ScrollDownButton>
        </SelectPrimitive.Content>
      </SelectPrimitive.Portal>
    </SelectPrimitive.Root>
  );
}
