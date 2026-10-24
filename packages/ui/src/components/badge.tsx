import type { HTMLAttributes, ReactNode } from 'react';
import { cva } from 'class-variance-authority';
import { cn } from '../lib/cn';
import { Icon, type IconName } from './icon';

export type BadgeTone = 'neutral' | 'primary' | 'success' | 'warn' | 'danger' | 'paid' | 'premium' | 'outline' | 'hot' | 'glass';

/* DS 09 §3 + DS 11 §5: pill chips, 12/700, soft background + dark-enough text (all ≥ 4.5:1). */
export const badgeVariants = cva('inline-flex max-w-full shrink-0 items-center gap-1 rounded-full font-bold whitespace-nowrap', {
  variants: {
    tone: {
      neutral: 'bg-subtle text-text-2',
      primary: 'bg-primary-soft text-primary-soft-fg',
      success: 'bg-success-bg text-success-fg',
      warn: 'bg-warn-bg text-warn-fg',
      danger: 'bg-danger-bg text-danger-fg',
      paid: 'bg-paid-bg text-paid-fg',
      premium: 'bg-premium-bg text-premium-fg',
      outline: 'border border-border-strong bg-surface text-text-2',
      hot: 'bg-danger text-white',
      glass: 'surface-glass-dark',
    },
    size: {
      sm: 'h-5 px-2 text-[11px]',
      md: 'h-6 px-2.5 text-caption font-bold',
    },
  },
  defaultVariants: { tone: 'neutral', size: 'md' },
});

const DOT: Record<BadgeTone, string> = {
  neutral: 'bg-muted',
  primary: 'bg-primary',
  success: 'bg-success',
  warn: 'bg-warn',
  danger: 'bg-danger',
  paid: 'bg-paid',
  premium: 'bg-premium',
  outline: 'bg-muted',
  hot: 'bg-white',
  glass: 'bg-white',
};

export interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  tone?: BadgeTone;
  size?: 'sm' | 'md';
  /** Leading status dot. `pulse` animates it (live states). */
  dot?: boolean | 'pulse';
  icon?: IconName;
  children?: ReactNode;
}

/** Small status/label chip. Server-compatible. */
export function Badge({ tone = 'neutral', size = 'md', dot, icon, className, children, ...rest }: BadgeProps) {
  return (
    <span className={cn(badgeVariants({ tone, size }), className)} {...rest}>
      {dot ? (
        <span aria-hidden className="relative inline-flex size-1.5">
          {dot === 'pulse' ? <span className={cn('absolute inset-0 animate-ping rounded-full opacity-60', DOT[tone])} /> : null}
          <span className={cn('relative inline-flex size-1.5 rounded-full', DOT[tone])} />
        </span>
      ) : null}
      {icon ? <Icon name={icon} size={size === 'sm' ? 12 : 14} filled /> : null}
      {children != null ? <span className="truncate">{children}</span> : null}
    </span>
  );
}

/* ───────────────────────── Domain statuses → tone ───────────────────────── */

export const STATUS_KINDS = {
  campaign: ['draft', 'in_review', 'scheduled', 'live', 'paused', 'tracking', 'exhausted', 'settling', 'settled', 'rejected', 'cancelled'],
  submission: ['validating', 'in_review', 'tracking', 'flagged', 'rejected', 'appealed', 'rejected_final', 'forfeited', 'locked', 'settled'],
  payout: ['requested', 'on_hold', 'processing', 'paid', 'failed', 'returned', 'cancelled'],
  fulfillment: ['requested', 'on_hold', 'processing', 'delivered', 'failed', 'returned', 'cancelled'],
  kyc: ['none', 'pending', 'approved', 'rejected'],
  org: ['pending_verification', 'verified', 'suspended'],
  claim: ['open', 'submitted', 'expired', 'released'],
  earning: ['pending', 'available', 'withdrawn'],
  profile: ['active', 'suspended', 'banned', 'closed'],
} as const;

export type StatusKind = keyof typeof STATUS_KINDS;
export type StatusOf<K extends StatusKind> = (typeof STATUS_KINDS)[K][number];

type StatusTone = Exclude<BadgeTone, 'outline' | 'hot' | 'glass'>;
interface StatusStyle {
  tone: StatusTone;
  icon?: IconName;
  /** Live/ongoing states show a pulsing dot instead of an icon. */
  live?: boolean;
}

const STATUS_MAP: { [K in StatusKind]: Record<StatusOf<K>, StatusStyle> } = {
  campaign: {
    draft: { tone: 'neutral', icon: 'edit' },
    in_review: { tone: 'warn', icon: 'schedule' },
    scheduled: { tone: 'primary', icon: 'calendar_today' },
    live: { tone: 'success', live: true },
    paused: { tone: 'warn', icon: 'pause' },
    tracking: { tone: 'primary', icon: 'monitoring' },
    exhausted: { tone: 'danger', icon: 'local_fire_department' },
    settling: { tone: 'primary', icon: 'hourglass_top' },
    settled: { tone: 'paid', icon: 'payments' },
    rejected: { tone: 'danger', icon: 'cancel' },
    cancelled: { tone: 'neutral', icon: 'block' },
  },
  submission: {
    validating: { tone: 'primary', icon: 'progress_activity' },
    in_review: { tone: 'warn', icon: 'schedule' },
    tracking: { tone: 'primary', live: true },
    flagged: { tone: 'danger', icon: 'flag' },
    rejected: { tone: 'danger', icon: 'cancel' },
    appealed: { tone: 'warn', icon: 'gavel' },
    rejected_final: { tone: 'danger', icon: 'block' },
    forfeited: { tone: 'neutral', icon: 'block' },
    locked: { tone: 'success', icon: 'lock' },
    settled: { tone: 'paid', icon: 'payments' },
  },
  payout: {
    requested: { tone: 'primary', icon: 'schedule' },
    on_hold: { tone: 'warn', icon: 'pause' },
    processing: { tone: 'primary', icon: 'progress_activity' },
    paid: { tone: 'paid', icon: 'check_circle' },
    failed: { tone: 'danger', icon: 'error' },
    returned: { tone: 'danger', icon: 'undo' },
    cancelled: { tone: 'neutral', icon: 'block' },
  },
  fulfillment: {
    requested: { tone: 'primary', icon: 'schedule' },
    on_hold: { tone: 'warn', icon: 'pause' },
    processing: { tone: 'primary', icon: 'progress_activity' },
    delivered: { tone: 'paid', icon: 'check_circle' },
    failed: { tone: 'danger', icon: 'error' },
    returned: { tone: 'danger', icon: 'undo' },
    cancelled: { tone: 'neutral', icon: 'block' },
  },
  kyc: {
    none: { tone: 'neutral', icon: 'id_card' },
    pending: { tone: 'warn', icon: 'schedule' },
    approved: { tone: 'success', icon: 'verified' },
    rejected: { tone: 'danger', icon: 'cancel' },
  },
  org: {
    pending_verification: { tone: 'warn', icon: 'schedule' },
    verified: { tone: 'success', icon: 'verified' },
    suspended: { tone: 'danger', icon: 'block' },
  },
  claim: {
    open: { tone: 'primary', icon: 'timer' },
    submitted: { tone: 'success', icon: 'check_circle' },
    expired: { tone: 'neutral', icon: 'schedule' },
    released: { tone: 'neutral', icon: 'undo' },
  },
  earning: {
    pending: { tone: 'warn', icon: 'schedule' },
    available: { tone: 'success', icon: 'account_balance_wallet' },
    withdrawn: { tone: 'paid', icon: 'payments' },
  },
  profile: {
    active: { tone: 'success', icon: 'check_circle' },
    suspended: { tone: 'warn', icon: 'pause' },
    banned: { tone: 'danger', icon: 'block' },
    closed: { tone: 'neutral', icon: 'block' },
  },
};

function styleOf(kind: StatusKind, status: string): StatusStyle {
  return (STATUS_MAP[kind] as Record<string, StatusStyle>)[status] ?? { tone: 'neutral' };
}

/** Map a domain status to a badge tone. Unknown statuses → "neutral". */
export function statusTone(kind: StatusKind, status: string): StatusTone {
  return styleOf(kind, status).tone;
}

export interface StatusBadgeProps<K extends StatusKind = StatusKind> extends Omit<BadgeProps, 'tone' | 'children' | 'dot' | 'icon'> {
  kind: K;
  status: StatusOf<K> | (string & {});
  /** Translated label from the app (i18n lives in apps). */
  label: ReactNode;
  /** Hide the status icon / live dot. */
  plain?: boolean;
}

/** Badge whose colour + icon follow the domain status ("status tidak ambigu: satu warna, satu ikon"). */
export function StatusBadge<K extends StatusKind>({ kind, status, label, plain, ...rest }: StatusBadgeProps<K>) {
  const s = styleOf(kind, status);
  return (
    <Badge tone={s.tone} dot={!plain && s.live ? 'pulse' : undefined} icon={!plain && !s.live ? s.icon : undefined} data-status={status} {...rest}>
      {label}
    </Badge>
  );
}
