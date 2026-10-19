import type { SVGProps } from 'react';
import { cn } from '../lib/cn';

/** Platforms supported by campaigns (matches market.platform enum). */
export const PLATFORMS = ['tiktok', 'instagram', 'youtube', 'threads', 'facebook', 'x'] as const;
export type Platform = (typeof PLATFORMS)[number];

export const platformLabels: Record<Platform, string> = {
  tiktok: 'TikTok',
  instagram: 'Instagram',
  youtube: 'YouTube',
  threads: 'Threads',
  facebook: 'Facebook',
  x: 'X',
};

export function platformLabel(platform: Platform): string {
  return platformLabels[platform];
}

/*
 * Simple monochrome marks drawn for this DS on a 24-unit grid (basic glyph shapes only, single colour,
 * no official artwork). They inherit currentColor so they work on light, dark and glass chips.
 */
function Mark({ platform }: { platform: Platform }) {
  switch (platform) {
    case 'tiktok':
      return (
        <path d="M16.6 3h-3.3v11.9a2.8 2.8 0 1 1-2.8-2.8c.3 0 .6 0 .9.1V8.8a6.2 6.2 0 1 0 5.2 6.1V9.1A7.7 7.7 0 0 0 21 10.6V7.3a4.4 4.4 0 0 1-4.4-4.3Z" />
      );
    case 'instagram':
      return (
        <path
          fillRule="evenodd"
          d="M8 2.5h8A5.5 5.5 0 0 1 21.5 8v8a5.5 5.5 0 0 1-5.5 5.5H8A5.5 5.5 0 0 1 2.5 16V8A5.5 5.5 0 0 1 8 2.5Zm0 2A3.5 3.5 0 0 0 4.5 8v8A3.5 3.5 0 0 0 8 19.5h8a3.5 3.5 0 0 0 3.5-3.5V8A3.5 3.5 0 0 0 16 4.5H8Zm4 3a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9Zm0 2a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5Zm5-3.3a1.2 1.2 0 1 1 0 2.4 1.2 1.2 0 0 1 0-2.4Z"
        />
      );
    case 'youtube':
      return (
        <path
          fillRule="evenodd"
          d="M21.6 7.2a2.6 2.6 0 0 0-1.8-1.8C18.2 5 12 5 12 5s-6.2 0-7.8.4a2.6 2.6 0 0 0-1.8 1.8C2 8.8 2 12 2 12s0 3.2.4 4.8c.2.9.9 1.6 1.8 1.8 1.6.4 7.8.4 7.8.4s6.2 0 7.8-.4a2.6 2.6 0 0 0 1.8-1.8c.4-1.6.4-4.8.4-4.8s0-3.2-.4-4.8ZM10 15.1V8.9l5.2 3.1-5.2 3.1Z"
        />
      );
    case 'threads':
      return (
        <path d="M12.2 22c-2.9 0-5.1-.9-6.6-2.7C4.3 17.7 3.6 15.4 3.6 12.5v-.1c0-2.9.7-5.2 2-6.8C7.1 3.9 9.3 3 12.2 3h.1c2.2 0 4.1.6 5.5 1.7 1.3 1 2.2 2.5 2.7 4.3l-2 .5c-.8-3-3-4.5-6.3-4.5-2.2 0-3.9.7-5 2.1-1 1.3-1.6 3.1-1.6 5.4 0 2.3.5 4.1 1.6 5.4 1.1 1.4 2.8 2.1 5 2.1 2 0 3.3-.5 4.4-1.6 1.2-1.2 1.2-2.7.8-3.6-.2-.5-.6-1-1.2-1.3-.1 1-.4 1.8-.9 2.5-.7.9-1.7 1.4-3 1.5-1 .1-2-.2-2.7-.7-.8-.6-1.3-1.4-1.3-2.4-.1-1.9 1.4-3.2 3.8-3.4.8 0 1.6 0 2.3.1-.1-.6-.3-1-.6-1.3-.4-.4-1-.6-1.8-.6-.9 0-1.6.3-2.1 1l-1.6-1.1c.8-1.1 2.1-1.7 3.7-1.7h.1c2.7 0 4.2 1.6 4.4 4.5l.3.1c1.3.6 2.2 1.5 2.7 2.6.7 1.6.7 4.1-1.3 6.1-1.5 1.5-3.4 2.2-6 2.2Zm.8-9.8h-.6c-1.6.1-2.1.8-2.1 1.4 0 .8.9 1.2 1.7 1.1.8 0 1.8-.3 2-2.3-.3-.1-.6-.2-1-.2Z" />
      );
    case 'facebook':
      return (
        <path
          fillRule="evenodd"
          d="M12 2a10 10 0 0 0-1.6 19.9v-7H7.9V12h2.5V9.8c0-2.5 1.5-3.9 3.8-3.9 1.1 0 2.2.2 2.2.2v2.5h-1.3c-1.2 0-1.6.8-1.6 1.6V12h2.8l-.4 2.9h-2.3v7A10 10 0 0 0 12 2Z"
        />
      );
    case 'x':
      return <path d="M17.8 3h3.1l-6.7 7.7L22 21h-6.2l-4.8-6.3L5.5 21H2.4l7.2-8.2L2 3h6.3l4.4 5.8L17.8 3Zm-1.1 16.2h1.7L7.4 4.7H5.6l11.1 14.5Z" />;
  }
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
