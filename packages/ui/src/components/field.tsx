import { Children, cloneElement, isValidElement, useId, type ReactElement, type ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Icon } from './icon';

/** Props a Field hands to its control (spread them on custom controls when using the render-prop form). */
export interface FieldControlProps {
  id: string;
  'aria-describedby'?: string;
  'aria-invalid'?: true;
  required?: boolean;
}

export interface FieldProps {
  /** Visible label (DS: always visible, 14/600, above the field — never placeholder-only). */
  label: ReactNode;
  /** Control id. Generated when omitted. */
  id?: string;
  /** Helper text: format example or context (DS 08 §4). Replaced by `error` when present. */
  helper?: ReactNode;
  /** Error message that says how to fix it. Sets aria-invalid and is linked via aria-describedby. */
  error?: ReactNode;
  /** Success message (e.g. "Link valid · 0:21"). */
  success?: ReactNode;
  /** Red asterisk after the label + `required` on the control. */
  required?: boolean;
  /** Shows "(opsional)" after the label, or a custom text. */
  optional?: boolean | ReactNode;
  /** Right-aligned slot in the label row (e.g. "Lupa password?" link or a counter). */
  labelAside?: ReactNode;
  /** Visually hide the label (still read by screen readers). */
  labelHidden?: boolean;
  className?: string;
  /**
   * A single control element (Input, Textarea, Select, native input…) — it receives id/aria props —
   * or a render function receiving those props.
   */
  children: ReactElement | ((control: FieldControlProps & { invalid: boolean }) => ReactNode);
}

/**
 * Label + control + helper/error, wired for assistive tech (htmlFor, aria-describedby, aria-invalid).
 * Server-compatible (useId works in RSC).
 */
export function Field({
  label,
  id: idProp,
  helper,
  error,
  success,
  required,
  optional,
  labelAside,
  labelHidden,
  className,
  children,
}: FieldProps) {
  const autoId = useId();
  const id = idProp ?? `f${autoId.replace(/[^a-zA-Z0-9_-]/g, '')}`;
  const helperId = `${id}-helper`;
  const messageId = `${id}-msg`;
  const invalid = error != null && error !== false && error !== '';
  const message = invalid ? error : success;
  const describedBy = [helper && !invalid ? helperId : null, message ? messageId : null].filter(Boolean).join(' ') || undefined;
  const control: FieldControlProps = {
    id,
    'aria-describedby': describedBy,
    'aria-invalid': invalid ? true : undefined,
    required: required || undefined,
  };

  let rendered: ReactNode;
  if (typeof children === 'function') {
    rendered = children({ ...control, invalid });
  } else {
    const child = Children.only(children);
    if (isValidElement<Record<string, unknown>>(child)) {
      const existing = typeof child.props['aria-describedby'] === 'string' ? (child.props['aria-describedby'] as string) : '';
      const extra: Record<string, unknown> = {
        id: (child.props.id as string | undefined) ?? id,
        'aria-describedby': [existing, describedBy].filter(Boolean).join(' ') || undefined,
        'aria-invalid': control['aria-invalid'],
        required: (child.props.required as boolean | undefined) ?? control.required,
      };
      // DS components accept `invalid`/`success`; native elements must not receive unknown props.
      if (typeof child.type !== 'string') {
        extra.invalid = invalid || undefined;
        if (success && !invalid) extra.success = true;
      }
      rendered = cloneElement(child, extra);
    } else {
      rendered = child;
    }
  }

  return (
    <div className={cn('flex flex-col gap-1.5', className)}>
      <div className={cn('flex items-baseline justify-between gap-3', labelHidden && 'sr-only')}>
        <label htmlFor={id} className="text-label text-ink">
          {label}
          {required ? (
            <span aria-hidden className="ml-0.5 font-bold text-danger">
              *
            </span>
          ) : null}
          {optional && !required ? (
            <span className="ml-1 font-medium text-muted">{optional === true ? '(opsional)' : optional}</span>
          ) : null}
        </label>
        {labelAside ? <div className="text-caption text-muted">{labelAside}</div> : null}
      </div>
      {rendered}
      {helper && !invalid ? (
        <p id={helperId} className="text-caption text-muted">
          {helper}
        </p>
      ) : null}
      {message ? (
        <p
          id={messageId}
          role={invalid ? 'alert' : 'status'}
          className={cn('flex items-start gap-1 text-caption font-medium', invalid ? 'text-danger-fg' : 'text-success-fg')}
        >
          <Icon name={invalid ? 'error' : 'check_circle'} size={14} filled className="mt-px" />
          <span>{message}</span>
        </p>
      ) : null}
    </div>
  );
}

export interface FieldsetProps {
  legend: ReactNode;
  description?: ReactNode;
  error?: ReactNode;
  className?: string;
  children: ReactNode;
}

/** Groups related controls (radio/checkbox groups) with a legend. */
export function Fieldset({ legend, description, error, className, children }: FieldsetProps) {
  const id = useId();
  return (
    <fieldset className={cn('flex min-w-0 flex-col gap-3', className)} aria-describedby={description || error ? `${id}-d` : undefined}>
      <legend className="mb-1 text-label text-ink">{legend}</legend>
      {children}
      {description || error ? (
        <p id={`${id}-d`} role={error ? 'alert' : undefined} className={cn('text-caption', error ? 'font-medium text-danger-fg' : 'text-muted')}>
          {error ?? description}
        </p>
      ) : null}
    </fieldset>
  );
}
