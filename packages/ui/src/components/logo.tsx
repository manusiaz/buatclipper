import type { ElementType, ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Icon } from './icon';

export interface LogoMarkProps {
  /** Tile size in px. Default 34 (DS 02: symbol 34 px, wordmark 26 px). */
  size?: number;
  variant?: LogoVariant;
  className?: string;
  /** Accessible name when the mark is used alone. */
  title?: string;
}

export type LogoVariant = 'default' | 'on-dark' | 'on-blue' | 'mono';

/** Brand tile: blue gradient, radius 30 %, paper-plane rotated −32°. */
export function LogoMark({ size = 34, variant = 'default', className, title }: LogoMarkProps) {
  return (
    <span
      role={title ? 'img' : undefined}
      aria-label={title}
      aria-hidden={title ? undefined : true}
      className={cn(
        'inline-grid shrink-0 place-items-center rounded-[30%]',
        variant === 'on-blue' ? 'bg-white text-primary' : variant === 'mono' ? 'bg-navy text-white dark:bg-white dark:text-navy' : 'bg-cta text-white',
        variant === 'default' && 'shadow-[inset_0_1px_0_rgb(255_255_255/0.25),0_6px_12px_-6px_rgb(29_91_255/0.6)]',
        className,
      )}
      style={{ width: size, height: size }}
    >
      <Icon name="send" filled size={Math.round(size * 0.59)} style={{ transform: 'rotate(-32deg) translate(4%, -4%)' }} />
    </span>
  );
}

export interface LogoProps {
  /** Wordmark text. Default "Clipper" (DS: always "Clipper", never uppercase). */
  name?: string;
  /** Tile size in px; the wordmark scales with it (26/34). Default 32. */
  size?: number;
  variant?: LogoVariant;
  /** Render only the symbol (below 80 px wide, DS 02 §6). */
  markOnly?: boolean;
  /** Optional suffix after a divider, e.g. "Brand" or "Admin". */
  product?: ReactNode;
  href?: string;
  /** Link component (e.g. next/link) used when `href` is set. */
  linkAs?: ElementType;
  className?: string;
}

/** Logo = mark + wordmark. With `href` it renders a link (accessible name = `name`). Server-compatible. */
export function Logo({ name = 'Clipper', size = 32, variant = 'default', markOnly, product, href, linkAs, className }: LogoProps) {
  const wordColor = variant === 'on-dark' || variant === 'on-blue' ? 'text-white' : 'text-ink';
  const content = (
    <>
      <LogoMark size={size} variant={variant} title={markOnly && !href ? name : undefined} />
      {markOnly ? null : (
        <span className={cn('font-extrabold leading-none tracking-[-0.03em]', wordColor)} style={{ fontSize: Math.round(size * 0.76) }}>
          {name}
        </span>
      )}
      {product && !markOnly ? (
        <>
          <span aria-hidden className={cn('h-[0.8em] w-px', variant === 'default' || variant === 'mono' ? 'bg-border-strong' : 'bg-white/40')} style={{ fontSize: Math.round(size * 0.76) }} />
          <span className={cn('text-overline font-bold uppercase', variant === 'default' || variant === 'mono' ? 'text-muted' : 'text-white/80')}>{product}</span>
        </>
      ) : null}
    </>
  );
  const cls = cn('inline-flex items-center gap-2.5 select-none', className);
  if (href) {
    const Comp = linkAs ?? 'a';
    return (
      <Comp href={href} className={cn(cls, 'focus-ring rounded-control')} aria-label={markOnly ? name : undefined}>
        {content}
      </Comp>
    );
  }
  return <span className={cls}>{content}</span>;
}
