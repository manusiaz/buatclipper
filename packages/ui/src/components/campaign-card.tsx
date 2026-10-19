import type { ElementType, ReactNode } from 'react';
import { cn } from '../lib/cn';
import { earningFor, formatCompact, formatIDR, formatNumber, type UiLocale } from '../lib/format';
import { Avatar } from './avatar';
import { Badge } from './badge';
import { Button } from './button';
import { Countdown } from './countdown';
import { Icon, type IconName } from './icon';
import { PlatformIcon, platformLabels, type Platform } from './platform-icon';
import { ProgressBar } from './progress-bar';
import { RelativeTime } from './relative-time';

/** CTA per user from api.list_campaigns (F-C03). */
export type CampaignCtaState = 'can_claim' | 'claimed_not_submitted' | 'slots_full' | 'budget_exhausted' | 'deadline_passed' | 'not_eligible';

export interface CampaignCardLabels {
  pinned: string;
  isNew: string;
  perViews: string;
  viewsLeft: (compact: string) => string;
  example: (views: string, earning: string) => string;
  creators: (n: string) => string;
  deadlinePrefix: string;
  budgetUsed: string;
  cta: Record<CampaignCtaState, string>;
  claimExpires: string;
}

const LABELS_ID: CampaignCardLabels = {
  pinned: 'Pinned',
  isNew: 'Baru',
  perViews: '/1K views',
  viewsLeft: (c) => `± ${c} views lagi`,
  example: (v, e) => `${v} views = ${e}`,
  creators: (n) => `${n} kreator`,
  deadlinePrefix: 'Berakhir',
  budgetUsed: 'Budget terpakai',
  cta: {
    can_claim: 'Ambil Campaign',
    claimed_not_submitted: 'Kirim Video',
    slots_full: 'Slot penuh',
    budget_exhausted: 'Budget habis',
    deadline_passed: 'Deadline lewat',
    not_eligible: 'Belum memenuhi syarat',
  },
  claimExpires: 'Sisa waktu',
};

const LABELS_EN: CampaignCardLabels = {
  pinned: 'Pinned',
  isNew: 'New',
  perViews: '/1K views',
  viewsLeft: (c) => `± ${c} views left`,
  example: (v, e) => `${v} views = ${e}`,
  creators: (n) => `${n} creators`,
  deadlinePrefix: 'Ends',
  budgetUsed: 'Budget used',
  cta: {
    can_claim: 'Claim campaign',
    claimed_not_submitted: 'Submit video',
    slots_full: 'Slots full',
    budget_exhausted: 'Budget used up',
    deadline_passed: 'Deadline passed',
    not_eligible: 'Not eligible yet',
  },
  claimExpires: 'Time left',
};

export interface CampaignRate {
  platform: Platform;
  /** IDR per 1.000 views. */
  ratePer1k: number;
}

export interface CampaignCardProps {
  title: string;
  /** Detail page; makes the whole card clickable (stretched link on the title). */
  href?: string;
  linkAs?: ElementType;
  coverSrc?: string | null;
  coverAlt?: string;
  brand?: { name: string; logoSrc?: string | null; verified?: boolean };
  category?: string;
  /** Category icon for the cover placeholder. */
  categoryIcon?: IconName;
  platforms: Platform[];
  /** Rate per platform; the highest is shown big (DS: "Rate = angka paling gede di kartu"). */
  rates: CampaignRate[];
  pinned?: boolean;
  isNew?: boolean;
  /** Optional status badge (e.g. <StatusBadge kind="campaign" …/>) on the cover. Max 1 status + 1 platform chip. */
  status?: ReactNode;
  /** Submit deadline (ISO) → "12 hari lagi". */
  deadline?: string | Date;
  /** Views the remaining budget can still pay for → "± 5,8 jt views lagi". */
  remainingViews?: number;
  /** 0–1 share of budget already used (bar fills; red ≥ 90 %). */
  budgetUsedRatio?: number;
  /** Example earning line; default 10.000 views at the highest rate. Set 0 to hide. */
  exampleViews?: number;
  creatorsCount?: number;
  /** CTA state from the API. Ignored when `cta` is given. */
  ctaState?: CampaignCtaState;
  /** Primary CTA target (can_claim / claimed_not_submitted). Use a link or `onCtaClick` (client parent). */
  ctaHref?: string;
  onCtaClick?: () => void;
  ctaLoading?: boolean;
  /** Reason shown under blocked/closed states, e.g. "Hubungkan akun TikTok dulu." */
  ctaReason?: ReactNode;
  /** Fix-it action for `not_eligible`, e.g. { label: "Hubungkan akun", href: "/social?next=…" }. */
  ctaAction?: { label: string; href: string };
  /** Claim window end (claimed_not_submitted) → countdown "47 j 12 m". */
  claimExpiresAt?: string | Date;
  /** Fully custom CTA slot. */
  cta?: ReactNode;
  /** Top-right slot on the cover (e.g. bookmark IconButton variant="glass"). */
  coverAction?: ReactNode;
  layout?: 'vertical' | 'horizontal';
  locale?: UiLocale;
  labels?: Partial<CampaignCardLabels>;
  className?: string;
}

function CtaBlock({
  state,
  labels,
  href,
  linkAs,
  onClick,
  loading,
  reason,
  action,
  claimExpiresAt,
  locale,
}: {
  state: CampaignCtaState;
  labels: CampaignCardLabels;
  href?: string;
  linkAs?: ElementType;
  onClick?: () => void;
  loading?: boolean;
  reason?: ReactNode;
  action?: { label: string; href: string };
  claimExpiresAt?: string | Date;
  locale: UiLocale;
}) {
  const label = labels.cta[state];
  if (state === 'can_claim') {
    return href ? (
      <Button href={href} linkAs={linkAs} fullWidth iconRight="arrow_forward" loading={loading} className="relative z-10">
        {label}
      </Button>
    ) : (
      <Button fullWidth iconRight="arrow_forward" onClick={onClick} loading={loading} className="relative z-10">
        {label}
      </Button>
    );
  }
  if (state === 'claimed_not_submitted') {
    return (
      <div className="relative z-10 flex flex-col gap-1.5">
        {href ? (
          <Button href={href} linkAs={linkAs} variant="ink" fullWidth iconLeft="upload" loading={loading}>
            {label}
          </Button>
        ) : (
          <Button variant="ink" fullWidth iconLeft="upload" onClick={onClick} loading={loading}>
            {label}
          </Button>
        )}
        {claimExpiresAt ? (
          <p className="flex items-center justify-center gap-1 text-caption text-muted">
            {labels.claimExpires}
            <Countdown target={claimExpiresAt} locale={locale} withIcon className="text-ink" />
          </p>
        ) : null}
      </div>
    );
  }

  // Closed / blocked states: never look like a button. Non-interactive status box + reason.
  const closed: Record<Exclude<CampaignCtaState, 'can_claim' | 'claimed_not_submitted'>, { icon: IconName; cls: string }> = {
    slots_full: { icon: 'groups', cls: 'border-border bg-disabled text-text-2' },
    budget_exhausted: { icon: 'local_fire_department', cls: 'border-danger-border/70 bg-danger-bg/60 text-danger-fg' },
    deadline_passed: { icon: 'schedule', cls: 'border-border bg-disabled text-muted' },
    not_eligible: { icon: 'lock', cls: 'border-dashed border-border-hover bg-surface text-text-2' },
  };
  const c = closed[state];
  return (
    <div className="relative z-10 flex flex-col gap-1.5" role="group" aria-label={label}>
      <div
        aria-disabled="true"
        className={cn('flex h-11 items-center justify-center gap-2 rounded-control border-[1.5px] text-sm font-bold md:h-10', c.cls)}
      >
        <Icon name={c.icon} size={18} filled={state !== 'not_eligible'} />
        {label}
      </div>
      {reason || action ? (
        <p className="flex flex-wrap items-center justify-center gap-x-1.5 text-center text-caption text-muted">
          {reason ? <span>{reason}</span> : null}
          {action ? (
            <Button href={action.href} linkAs={linkAs} variant="link" size="sm" iconRight="arrow_forward" className="text-caption font-bold">
              {action.label}
            </Button>
          ) : null}
        </p>
      ) : null}
    </div>
  );
}

/**
 * Campaign card (DS 09 anatomy): cover 16:10 with status/pinned/new + glass platform chip, brand, 2-line title,
 * big rate per 1K views, remaining budget in views + bar, example earning, deadline, one CTA (6 states).
 * Server-compatible; Countdown/RelativeTime inside are client islands.
 */
export function CampaignCard({
  title,
  href,
  linkAs,
  coverSrc,
  coverAlt = '',
  brand,
  category,
  categoryIcon = 'movie',
  platforms,
  rates,
  pinned,
  isNew,
  status,
  deadline,
  remainingViews,
  budgetUsedRatio,
  exampleViews = 10_000,
  creatorsCount,
  ctaState,
  ctaHref,
  onCtaClick,
  ctaLoading,
  ctaReason,
  ctaAction,
  claimExpiresAt,
  cta,
  coverAction,
  layout = 'vertical',
  locale = 'id',
  labels: labelsProp,
  className,
}: CampaignCardProps) {
  const labels = { ...(locale === 'en' ? LABELS_EN : LABELS_ID), ...labelsProp, cta: { ...(locale === 'en' ? LABELS_EN : LABELS_ID).cta, ...labelsProp?.cta } };
  const sorted = [...rates].sort((a, b) => b.ratePer1k - a.ratePer1k);
  const top = sorted[0];
  const ratesDiffer = sorted.length > 1 && sorted.some((r) => r.ratePer1k !== top?.ratePer1k);
  const closed = ctaState === 'budget_exhausted' || ctaState === 'deadline_passed' || ctaState === 'slots_full';
  const TitleLink = linkAs ?? 'a';
  const horizontal = layout === 'horizontal';

  const platformChip = platforms.length ? (
    <span className="surface-glass-dark inline-flex h-6 items-center gap-1 rounded-full px-2 text-[11px] font-bold">
      {platforms.slice(0, 3).map((p) => (
        <PlatformIcon key={p} platform={p} size={13} />
      ))}
      <span className="sr-only">{platforms.map((p) => platformLabels[p]).join(', ')}</span>
      <span aria-hidden className={cn('ml-0.5', platforms.length > 1 && 'max-sm:hidden')}>
        {platforms.length === 1 ? platformLabels[platforms[0]!] : `${platforms.length} platform`}
      </span>
    </span>
  ) : null;

  return (
    <article
      className={cn(
        'group/card surface-card relative isolate flex overflow-hidden rounded-card text-ink',
        'transition-[transform,box-shadow] duration-220 ease-out',
        href && 'hover:shadow-card-hover motion-safe:hover:-translate-y-1',
        href && 'has-[[data-card-link]:focus-visible]:shadow-[0_0_0_2px_var(--color-surface),0_0_0_4px_var(--color-focus),0_0_0_8px_var(--color-focus-halo)]',
        horizontal ? 'flex-row' : 'flex-col',
        closed && 'opacity-[0.92]',
        className,
      )}
    >
      {/* Cover */}
      <div className={cn('relative shrink-0 overflow-hidden bg-navy', horizontal ? 'w-[38%] min-w-28' : 'aspect-[16/10] w-full')}>
        {coverSrc ? (
          <img
            src={coverSrc}
            alt={coverAlt}
            loading="lazy"
            decoding="async"
            className={cn(
              'size-full object-cover transition-transform duration-500 ease-out motion-safe:group-hover/card:scale-[1.03]',
              closed && 'grayscale-[60%]',
            )}
          />
        ) : (
          <div className="grid size-full place-items-center bg-[radial-gradient(90%_70%_at_100%_0%,#1e3470_0%,#0a1226_60%)] text-white/60">
            <Icon name={categoryIcon} size={40} />
          </div>
        )}
        <div className="pointer-events-none absolute inset-0 bg-[linear-gradient(180deg,rgb(10_18_38/0.28),transparent_34%,transparent_62%,rgb(10_18_38/0.45))]" />
        <div className="absolute top-2.5 left-2.5 flex flex-wrap gap-1.5">
          {status}
          {pinned ? (
            <Badge tone="glass" icon="keep" size="sm">
              {labels.pinned}
            </Badge>
          ) : null}
          {isNew ? (
            <Badge tone="primary" size="sm" className="bg-white text-primary dark:bg-white dark:text-primary">
              {labels.isNew}
            </Badge>
          ) : null}
        </div>
        {coverAction ? <div className="absolute top-2 right-2 z-10">{coverAction}</div> : null}
        {!horizontal ? <div className="absolute bottom-2.5 left-2.5">{platformChip}</div> : null}
      </div>

      {/* Body */}
      <div className={cn('flex min-w-0 flex-1 flex-col gap-2.5', horizontal ? 'p-3.5' : 'px-3.5 pt-3 pb-3.5')}>
        {brand || category ? (
          <div className="flex min-w-0 items-center gap-1.5 text-caption text-muted">
            {brand ? (
              <>
                <Avatar name={brand.name} src={brand.logoSrc} size={18} shape="square" />
                <span className="truncate font-semibold text-text-2">{brand.name}</span>
                {brand.verified ? <Icon name="verified" size={14} filled className="shrink-0 text-primary" title="Terverifikasi" /> : null}
              </>
            ) : null}
            {brand && category ? <span aria-hidden>·</span> : null}
            {category ? <span className="truncate">{category}</span> : null}
          </div>
        ) : null}

        <h3 className="line-clamp-2 min-h-[2.5em] text-[15px] leading-[1.25] font-extrabold tracking-[-0.01em]">
          {href ? (
            <TitleLink href={href} data-card-link="" className="outline-none after:absolute after:inset-0 after:z-0 after:content-['']">
              {title}
            </TitleLink>
          ) : (
            title
          )}
        </h3>

        {top ? (
          <div className="flex items-end justify-between gap-2">
            <p className="leading-none">
              <span className="text-[22px] font-extrabold tracking-[-0.03em] tnum">{formatIDR(top.ratePer1k, { locale })}</span>
              <span className="ml-1 text-caption font-medium text-muted">{labels.perViews}</span>
            </p>
            {creatorsCount != null ? (
              <span className="flex items-center gap-1 text-caption text-muted">
                <Icon name="groups" size={14} />
                {labels.creators(formatNumber(creatorsCount, locale))}
              </span>
            ) : null}
          </div>
        ) : null}

        {ratesDiffer ? (
          <ul className="-mt-1 flex flex-wrap gap-x-2.5 gap-y-1 text-caption text-text-2" aria-label="Rate per platform">
            {sorted.map((r) => (
              <li key={r.platform} className="inline-flex items-center gap-1">
                <PlatformIcon platform={r.platform} size={12} className="text-muted" decorative={false} />
                <span className="font-semibold tnum">{formatIDR(r.ratePer1k, { locale })}</span>
              </li>
            ))}
          </ul>
        ) : null}

        {remainingViews != null || budgetUsedRatio != null ? (
          <div className="flex flex-col gap-1.5">
            {budgetUsedRatio != null ? (
              <ProgressBar value={budgetUsedRatio * 100} label={labels.budgetUsed} tone="auto" />
            ) : null}
            <div className="flex items-center justify-between gap-2 text-caption text-muted">
              {remainingViews != null ? (
                <span className={cn('font-semibold tnum', budgetUsedRatio != null && budgetUsedRatio >= 0.9 ? 'text-danger-fg' : 'text-text-2')}>
                  {labels.viewsLeft(formatCompact(remainingViews, locale))}
                </span>
              ) : (
                <span />
              )}
              {deadline ? (
                <span className="inline-flex items-center gap-1">
                  <Icon name="schedule" size={14} />
                  <RelativeTime value={deadline} locale={locale} />
                </span>
              ) : null}
            </div>
          </div>
        ) : deadline ? (
          <p className="inline-flex items-center gap-1 text-caption text-muted">
            <Icon name="schedule" size={14} />
            <RelativeTime value={deadline} locale={locale} />
          </p>
        ) : null}

        {exampleViews > 0 && top ? (
          <p className="flex items-center gap-1.5 rounded-chip bg-success-bg px-2.5 py-1.5 text-caption font-semibold text-success-fg">
            <Icon name="payments" size={14} filled />
            <span className="tnum">
              {labels.example(formatNumber(exampleViews, locale), formatIDR(earningFor(exampleViews, top.ratePer1k), { locale }))}
            </span>
          </p>
        ) : null}

        {horizontal && platformChip ? <div className="flex">{platformChip}</div> : null}

        <div className="mt-auto pt-0.5">
          {cta ??
            (ctaState ? (
              <CtaBlock
                state={ctaState}
                labels={labels}
                href={ctaHref}
                linkAs={linkAs}
                onClick={onCtaClick}
                loading={ctaLoading}
                reason={ctaReason}
                action={ctaAction}
                claimExpiresAt={claimExpiresAt}
                locale={locale}
              />
            ) : null)}
        </div>
      </div>
    </article>
  );
}
