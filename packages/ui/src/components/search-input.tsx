'use client';

import { useRef, useState, type ChangeEvent, type Ref } from 'react';
import { cn } from '../lib/cn';
import { Icon } from './icon';
import { Input, type InputProps } from './input';

export interface SearchInputProps extends Omit<InputProps, 'type' | 'iconLeft' | 'trailing' | 'prefix'> {
  /** Called with the new value on every change and on clear. */
  onValueChange?: (value: string) => void;
  onClear?: () => void;
  /** Accessible name when there is no visible label. Default "Cari". */
  'aria-label'?: string;
  /** Label for the clear button. Default "Hapus pencarian". */
  clearLabel?: string;
  /** Keyboard hint shown on desktop, e.g. "/" or "⌘K". */
  shortcut?: string;
}

function assignRef<T>(ref: Ref<T> | undefined, value: T | null) {
  if (!ref) return;
  if (typeof ref === 'function') ref(value);
  else (ref as { current: T | null }).current = value;
}

/** Search field with leading icon and clear button (DS 08 §2). Works controlled or uncontrolled. */
export function SearchInput({
  value,
  defaultValue,
  onChange,
  onValueChange,
  onClear,
  clearLabel = 'Hapus pencarian',
  shortcut,
  placeholder = 'Cari campaign, brand, atau kreator',
  className,
  inputClassName,
  ref,
  ...rest
}: SearchInputProps) {
  const inner = useRef<HTMLInputElement | null>(null);
  const [uncontrolled, setUncontrolled] = useState(String(defaultValue ?? ''));
  const current = value !== undefined ? String(value) : uncontrolled;

  const handleChange = (e: ChangeEvent<HTMLInputElement>) => {
    if (value === undefined) setUncontrolled(e.target.value);
    onChange?.(e);
    onValueChange?.(e.target.value);
  };
  const clear = () => {
    if (value === undefined) setUncontrolled('');
    onValueChange?.('');
    onClear?.();
    inner.current?.focus();
  };

  return (
    <Input
      {...rest}
      ref={(el) => {
        inner.current = el;
        assignRef(ref, el);
      }}
      type="search"
      role="searchbox"
      aria-label={rest['aria-label'] ?? (rest.id ? undefined : 'Cari')}
      enterKeyHint="search"
      autoComplete="off"
      value={current}
      onChange={handleChange}
      placeholder={placeholder}
      iconLeft="search"
      className={className}
      inputClassName={cn('[&::-webkit-search-cancel-button]:appearance-none [&::-webkit-search-decoration]:appearance-none', inputClassName)}
      trailing={
        current ? (
          <button
            type="button"
            onClick={clear}
            aria-label={clearLabel}
            className="touch-target -mr-1 grid size-7 place-items-center rounded-full text-muted transition-colors duration-120 hover:bg-subtle hover:text-ink focus-ring"
          >
            <Icon name="close" size={18} />
          </button>
        ) : shortcut ? (
          <kbd className="hidden h-6 items-center rounded-tag border border-border-strong px-1.5 font-sans text-caption font-semibold text-muted md:inline-flex">
            {shortcut}
          </kbd>
        ) : null
      }
    />
  );
}
