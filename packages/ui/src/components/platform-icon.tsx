import type { SVGProps } from 'react';
import { cn } from '../lib/cn';
import { PLATFORM_PATHS, platformLabels, type Platform } from '../lib/platform-paths';

export { PLATFORMS, platformLabel, platformLabels, type Platform } from '../lib/platform-paths';

/*
 * Simple monochrome marks drawn for this DS on a 24-unit grid (basic glyph shapes only, single colour,
 * no official artwork). They inherit currentColor so they work on light, dark and glass chips.
 */
function Mark({ platform }: { platform: Platform }) {
  const { d, evenOdd } = PLATFORM_PATHS[platform];
  return <path d={d} fillRule={evenOdd ? 'evenodd' : undefined} />;
}

export interface PlatformIconProps extends Omit<SVGProps<SVGSVGElement>, 'children'> {
  platform: Platform;
  /** Pixel size. Default 18. */
  size?: number;
  /** Accessible name; defaults to the platform label when `decorative` is false. */
  title?: string;
  /** When true (default) the mark is aria-hidden — pair it with visible text. */
  decorative?: boolean;
}

/** Monochrome platform mark (TikTok, Instagram, YouTube, Threads, Facebook, X). Server-compatible. */
export function PlatformIcon({ platform, size = 18, title, decorative = true, className, ...rest }: PlatformIconProps) {
  const label = title ?? platformLabels[platform];
  const hidden = decorative && !title;
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="currentColor"
      aria-hidden={hidden ? true : undefined}
      role={hidden ? undefined : 'img'}
      aria-label={hidden ? undefined : label}
      focusable="false"
      className={cn('inline-block shrink-0', className)}
      {...rest}
    >
      {hidden ? null : <title>{label}</title>}
      <Mark platform={platform} />
    </svg>
  );
}

export interface PlatformChipProps {
  platform: Platform;
  /** Override the label (e.g. "Reels"). */
  label?: string;
  /** `glass` for chips on photos, `soft` for chips on surfaces. */
  tone?: 'glass' | 'soft' | 'outline';
  className?: string;
}

/** Mark + label chip, e.g. on campaign cards. */
export function PlatformChip({ platform, label, tone = 'soft', className }: PlatformChipProps) {
  return (
    <span
      className={cn(
        'inline-flex h-6 items-center gap-1 rounded-full px-2 text-caption font-bold whitespace-nowrap',
        tone === 'glass' && 'surface-glass-dark',
        tone === 'soft' && 'bg-subtle text-text-2',
        tone === 'outline' && 'border border-border-strong text-text-2',
        className,
      )}
    >
      <PlatformIcon platform={platform} size={13} />
      {label ?? platformLabels[platform]}
    </span>
  );
}
