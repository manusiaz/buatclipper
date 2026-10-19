import type { HTMLAttributes } from 'react';
import { cn } from '../lib/cn';
import { initials as getInitials } from '../lib/format';

export interface AvatarProps extends HTMLAttributes<HTMLSpanElement> {
  /** Person/brand name — used for initials and alt text. */
  name: string;
  src?: string | null;
  /** Pixel size. Default 36. */
  size?: number;
  /** `square` for brand logos (radius 30 % like the logo tile). */
  shape?: 'circle' | 'square';
  /** White ring (stacked avatars, on photos). */
  ring?: boolean;
}

const TINTS = [
  'bg-brand-200 text-brand-800',
  'bg-success-bg text-success-fg',
  'bg-warn-bg text-warn-fg',
  'bg-premium-bg text-premium-fg',
  'bg-paid-bg text-paid-fg',
  'bg-danger-bg text-danger-fg',
];

function hash(s: string) {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return Math.abs(h);
}

/** Image avatar with initials fallback underneath (shows if the image fails/loads slowly). Server-compatible. */
export function Avatar({ name, src, size = 36, shape = 'circle', ring, className, style, ...rest }: AvatarProps) {
  return (
    <span
      className={cn(
        'relative inline-grid shrink-0 place-items-center overflow-hidden font-extrabold select-none',
        shape === 'circle' ? 'rounded-full' : 'rounded-[30%]',
        TINTS[hash(name) % TINTS.length],
        ring && 'ring-2 ring-surface',
        className,
      )}
      style={{ width: size, height: size, fontSize: Math.max(10, Math.round(size * 0.38)), ...style }}
      {...rest}
    >
      <span aria-hidden={src ? true : undefined}>{getInitials(name)}</span>
      {src ? <img src={src} alt={name} loading="lazy" decoding="async" className="absolute inset-0 size-full object-cover" /> : null}
      {!src ? <span className="sr-only">{name}</span> : null}
    </span>
  );
}

export interface AvatarGroupProps {
  people: Array<{ name: string; src?: string | null }>;
  max?: number;
  size?: number;
  className?: string;
}

/** Overlapping avatars + "+N" (DS trust slot). */
export function AvatarGroup({ people, max = 4, size = 28, className }: AvatarGroupProps) {
  const shown = people.slice(0, max);
  const rest = people.length - shown.length;
  return (
    <span className={cn('inline-flex items-center', className)}>
      {shown.map((p, i) => (
        <Avatar key={`${p.name}-${i}`} name={p.name} src={p.src} size={size} ring className={i > 0 ? '-ml-2' : undefined} />
      ))}
      {rest > 0 ? (
        <span
          className="-ml-2 inline-grid place-items-center rounded-full bg-subtle text-[11px] font-bold text-text-2 ring-2 ring-surface"
          style={{ width: size, height: size }}
        >
          +{rest}
        </span>
      ) : null}
    </span>
  );
}
