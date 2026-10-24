import type { ElementType, ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Button } from './button';
import { Icon, type IconName } from './icon';

export interface StateAction {
  label: string;
  href?: string;
  onClick?: () => void;
  linkAs?: ElementType;
  icon?: IconName;
}

export interface EmptyStateProps {
  icon?: IconName;
  /** Icon chip tone. */
  tone?: 'primary' | 'success' | 'warn' | 'neutral';
  title: ReactNode;
  /** Say what to do next ("Pilih satu campaign, potong momennya, kirim link-nya di sini."). */
  body?: ReactNode;
  action?: StateAction;
  secondaryAction?: StateAction;
  /** Smaller variant inside cards/tables. */
  compact?: boolean;
  className?: string;
  children?: ReactNode;
}

const CHIP = {
  primary: 'bg-primary-soft text-primary-soft-fg',
  success: 'bg-success-bg text-success-fg',
  warn: 'bg-warn-bg text-warn-fg',
  neutral: 'bg-subtle text-text-2',
};

function ActionButton({ a, variant }: { a: StateAction; variant: 'primary' | 'secondary' }) {
  return a.href ? (
    <Button href={a.href} linkAs={a.linkAs} variant={variant} iconLeft={a.icon}>
      {a.label}
    </Button>
  ) : (
    <Button variant={variant} iconLeft={a.icon} onClick={a.onClick}>
      {a.label}
    </Button>
  );
}

/** Empty state = a way forward, never a dead end (DS 11 §9, 12 §6). Server-compatible. */
export function EmptyState({ icon = 'movie', tone = 'primary', title, body, action, secondaryAction, compact, className, children }: EmptyStateProps) {
  return (
    <div className={cn('flex flex-col items-center text-center', compact ? 'gap-2 px-4 py-8' : 'gap-3 px-6 py-12', className)}>
      <span className={cn('relative grid place-items-center rounded-[30%]', compact ? 'size-12' : 'size-16', CHIP[tone])}>
        <Icon name={icon} size={compact ? 24 : 32} filled />
      </span>
      <h3 className={cn('text-ink', compact ? 'text-h6' : 'text-h5')}>{title}</h3>
      {body ? <p className="max-w-[44ch] text-body-s text-muted">{body}</p> : null}
      {children}
      {action || secondaryAction ? (
        <div className="mt-2 flex flex-wrap items-center justify-center gap-2">
          {secondaryAction ? <ActionButton a={secondaryAction} variant="secondary" /> : null}
          {action ? <ActionButton a={action} variant="primary" /> : null}
        </div>
      ) : null}
    </div>
  );
}

export interface ErrorStateProps extends Omit<EmptyStateProps, 'tone' | 'icon'> {
  icon?: IconName;
  /** Technical reference shown small for support ("Kode: core-503"). */
  code?: string;
}

/** Error with a recovery action ("Coba lagi"). role="alert". */
export function ErrorState({ icon = 'wifi_off', title, body, action, secondaryAction, compact, code, className, children }: ErrorStateProps) {
  return (
    <div role="alert" className={cn('flex flex-col items-center text-center', compact ? 'gap-2 px-4 py-8' : 'gap-3 px-6 py-12', className)}>
      <span className={cn('grid place-items-center rounded-[30%] bg-danger-bg text-danger-fg', compact ? 'size-12' : 'size-16')}>
        <Icon name={icon} size={compact ? 24 : 32} filled />
      </span>
      <h3 className={cn('text-ink', compact ? 'text-h6' : 'text-h5')}>{title}</h3>
      {body ? <p className="max-w-[44ch] text-body-s text-muted">{body}</p> : null}
      {children}
      {action || secondaryAction ? (
        <div className="mt-2 flex flex-wrap items-center justify-center gap-2">
          {secondaryAction ? <ActionButton a={secondaryAction} variant="secondary" /> : null}
          {action ? <ActionButton a={{ icon: 'refresh', ...action }} variant="primary" /> : null}
        </div>
      ) : null}
      {code ? <p className="font-mono text-caption text-faint">{code}</p> : null}
    </div>
  );
}
