import type { ElementType, HTMLAttributes, ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Button } from './button';
import { Icon, type IconName } from './icon';

export type AlertTone = 'info' | 'success' | 'warn' | 'danger';

const TONES: Record<AlertTone, { box: string; icon: IconName; iconCls: string; title: string }> = {
  info: { box: 'border-info-border bg-info-bg', icon: 'info', iconCls: 'bg-info text-white', title: 'text-info-fg' },
  success: { box: 'border-success-border bg-success-bg/70', icon: 'check_circle', iconCls: 'bg-success text-white', title: 'text-success-fg' },
  warn: { box: 'border-warn-border bg-warn-bg/70', icon: 'warning', iconCls: 'bg-warn text-white', title: 'text-warn-fg' },
  danger: { box: 'border-danger-border bg-danger-bg/70', icon: 'error', iconCls: 'bg-danger text-white', title: 'text-danger-fg' },
};

export interface AlertProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  tone?: AlertTone;
  title?: ReactNode;
  children?: ReactNode;
  icon?: IconName;
  /** One fix-it action (DS: "Error ada jalan keluar — satu tombol perbaiki"). */
  action?: { label: string; href?: string; onClick?: () => void; linkAs?: ElementType };
  /** Close control (client parent supplies the handler). */
  onDismiss?: () => void;
  dismissLabel?: string;
  /** `banner` = full-width strip at the top of a page (no radius on mobile). */
  variant?: 'inline' | 'banner';
}

/** Page/section status message (DS 12 §1). danger/warn use role="alert", others role="status". Server-compatible. */
export function Alert({ tone = 'info', title, children, icon, action, onDismiss, dismissLabel = 'Tutup', variant = 'inline', className, ...rest }: AlertProps) {
  const t = TONES[tone];
  return (
    <div
      role={tone === 'danger' || tone === 'warn' ? 'alert' : 'status'}
      className={cn(
        'relative flex items-start gap-3 border p-3.5 text-body-s text-ink',
        variant === 'banner' ? 'rounded-card-sm max-sm:rounded-none max-sm:border-x-0' : 'rounded-card-sm',
        t.box,
        className,
      )}
      {...rest}
    >
      <span className={cn('grid size-7 shrink-0 place-items-center rounded-full', t.iconCls)}>
        <Icon name={icon ?? t.icon} size={18} filled />
      </span>
      <div className="flex min-w-0 flex-1 flex-col gap-0.5 pt-0.5 sm:flex-row sm:items-center sm:gap-3">
        <div className="flex min-w-0 flex-1 flex-col gap-0.5">
          {title ? <p className={cn('font-bold', t.title)}>{title}</p> : null}
          {children ? <div className="text-text-2">{children}</div> : null}
        </div>
        {action ? (
          <div className="mt-1.5 shrink-0 sm:mt-0">
            {action.href ? (
              <Button href={action.href} linkAs={action.linkAs} size="sm" variant="secondary">
                {action.label}
              </Button>
            ) : (
              <Button size="sm" variant="secondary" onClick={action.onClick}>
                {action.label}
              </Button>
            )}
          </div>
        ) : null}
      </div>
      {onDismiss ? (
        <button
          type="button"
          onClick={onDismiss}
          aria-label={dismissLabel}
          className="touch-target relative -mt-0.5 -mr-1 grid size-7 shrink-0 place-items-center rounded-full text-muted hover:bg-black/5 hover:text-ink focus-ring dark:hover:bg-white/10"
        >
          <Icon name="close" size={18} />
        </button>
      ) : null}
    </div>
  );
}
