import type { InputHTMLAttributes, ReactNode, Ref, TextareaHTMLAttributes } from 'react';
import { cn } from '../lib/cn';
import { Icon, type IconName } from './icon';

/*
 * DS 08 Inputs: h 48, 16 px text (no iOS zoom), radius 12, border 1.5 strong → 2 px focus + 4 px halo,
 * error = red border + tinted bg, success = green border, disabled = subtle bg + 40 % text.
 */
export const fieldShellClasses = [
  'group/field relative flex w-full items-center gap-2 rounded-control border-[1.5px] border-border-strong bg-surface text-ink',
  'transition-[border-color,box-shadow,background-color] duration-120 ease-out',
  'hover:border-border-hover',
  'focus-within:border-focus focus-within:shadow-[0_0_0_4px_var(--color-focus-halo)] focus-within:hover:border-focus',
  'has-[:disabled]:border-border has-[:disabled]:bg-disabled has-[:disabled]:text-disabled-fg has-[:disabled]:hover:border-border',
  'data-[invalid=true]:border-danger data-[invalid=true]:bg-[color-mix(in_oklab,var(--color-surface),var(--color-danger-bg)_45%)]',
  'data-[invalid=true]:focus-within:shadow-[0_0_0_4px_color-mix(in_oklab,var(--color-danger)_20%,transparent)]',
  'data-[success=true]:border-success',
].join(' ');

const controlClasses =
  'min-w-0 flex-1 bg-transparent text-base text-ink outline-none placeholder:text-placeholder disabled:cursor-not-allowed disabled:text-disabled-fg';

export interface InputProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'size' | 'prefix'> {
  /** Error state: red border, aria-invalid. Pair with <Field error>. */
  invalid?: boolean;
  /** Success state: green border + check icon (e.g. "Link valid"). */
  success?: boolean;
  /** Leading Material Symbols icon (DS anatomy #4). */
  iconLeft?: IconName;
  /** Text/node before the value, e.g. "Rp". */
  prefix?: ReactNode;
  /** Text/node after the value, e.g. "/ 1K". */
  suffix?: ReactNode;
  /** Trailing slot (e.g. clear or visibility button). */
  trailing?: ReactNode;
  /** `md` = 48 px (DS default), `sm` = 40 px for toolbars and dense admin tables. */
  inputSize?: 'sm' | 'md';
  /** Class for the outer shell (border box). `className` also goes to the shell. */
  className?: string;
  /** Class for the <input> element itself. */
  inputClassName?: string;
  ref?: Ref<HTMLInputElement>;
}

/** Text input with optional icon, prefix/suffix and states. Server-compatible. */
export function Input({
  invalid,
  success,
  iconLeft,
  prefix,
  suffix,
  trailing,
  inputSize = 'md',
  className,
  inputClassName,
  ref,
  ...rest
}: InputProps) {
  const isInvalid = invalid ?? (rest['aria-invalid'] === true || rest['aria-invalid'] === 'true');
  return (
    <div
      className={cn(fieldShellClasses, inputSize === 'md' ? 'h-12 px-3.5' : 'h-10 px-3', className)}
      data-invalid={isInvalid || undefined}
      data-success={(success && !isInvalid) || undefined}
    >
      {iconLeft ? <Icon name={iconLeft} size={20} className="text-muted group-focus-within/field:text-primary-soft-fg" /> : null}
      {prefix != null ? <span className="text-base font-semibold text-muted select-none">{prefix}</span> : null}
      <input ref={ref} aria-invalid={isInvalid || undefined} className={cn(controlClasses, 'h-full', inputClassName)} {...rest} />
      {suffix != null ? <span className="text-sm font-medium whitespace-nowrap text-muted select-none">{suffix}</span> : null}
      {isInvalid ? <Icon name="error" size={20} filled className="text-danger" /> : null}
      {success && !isInvalid ? <Icon name="check_circle" size={20} filled className="text-success" /> : null}
      {trailing}
    </div>
  );
}

export interface TextareaProps extends TextareaHTMLAttributes<HTMLTextAreaElement> {
  invalid?: boolean;
  /** Show "80 / 500" counter (needs `maxLength`; counts `value` when controlled). */
  showCount?: boolean;
  className?: string;
  textareaClassName?: string;
  ref?: Ref<HTMLTextAreaElement>;
}

/** Multi-line input; grows with `rows`. Server-compatible. */
export function Textarea({ invalid, showCount, className, textareaClassName, rows = 4, ref, ...rest }: TextareaProps) {
  const isInvalid = invalid ?? (rest['aria-invalid'] === true || rest['aria-invalid'] === 'true');
  const length = typeof rest.value === 'string' ? rest.value.length : typeof rest.defaultValue === 'string' ? rest.defaultValue.length : 0;
  return (
    <div className={cn(fieldShellClasses, 'flex-col items-stretch gap-1 px-3.5 py-3', className)} data-invalid={isInvalid || undefined}>
      <textarea
        ref={ref}
        rows={rows}
        aria-invalid={isInvalid || undefined}
        className={cn(controlClasses, 'resize-y leading-6', textareaClassName)}
        {...rest}
      />
      {showCount && rest.maxLength ? (
        <span aria-hidden className="self-end text-caption text-muted tnum">
          {length} / {rest.maxLength}
        </span>
      ) : null}
    </div>
  );
}
