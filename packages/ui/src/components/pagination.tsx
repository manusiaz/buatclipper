import type { ElementType, ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Icon } from './icon';

export interface PaginationProps {
  page: number;
  pageCount: number;
  /** Link mode (server components): href for a page number. */
  getHref?: (page: number) => string;
  linkAs?: ElementType;
  /** Button mode (client components). */
  onPageChange?: (page: number) => void;
  /** Pages shown on each side of the current one. Default 1. */
  siblings?: number;
  labels?: { nav?: string; previous?: string; next?: string; page?: (n: number) => string };
  className?: string;
}

function range(page: number, count: number, siblings: number): Array<number | 'gap'> {
  const items: Array<number | 'gap'> = [];
  const start = Math.max(2, page - siblings);
  const end = Math.min(count - 1, page + siblings);
  items.push(1);
  if (start > 2) items.push('gap');
  for (let i = start; i <= end; i++) items.push(i);
  if (end < count - 1) items.push('gap');
  if (count > 1) items.push(count);
  return items;
}

const itemCls =
  'touch-target inline-grid h-10 min-w-10 place-items-center rounded-[11px] px-2 text-sm font-semibold text-text-2 tnum transition-colors duration-120 hover:bg-subtle hover:text-ink focus-ring';

/** Pagination (DS 10 §7): active page = blue gradient pill. Server-compatible in link mode. */
export function Pagination({ page, pageCount, getHref, linkAs, onPageChange, siblings = 1, labels, className }: PaginationProps) {
  if (pageCount <= 1) return null;
  const L = linkAs ?? 'a';
  const t = {
    nav: labels?.nav ?? 'Navigasi halaman',
    previous: labels?.previous ?? 'Sebelumnya',
    next: labels?.next ?? 'Berikutnya',
    page: labels?.page ?? ((n: number) => `Halaman ${n}`),
  };

  // Plain render helper (not a nested component) so client re-renders keep DOM nodes and focus.
  const item = (to: number, children: ReactNode, label: string, current?: boolean, disabled?: boolean) => {
    const cls = cn(
      itemCls,
      current && 'bg-cta font-extrabold text-white shadow-[0_6px_12px_-6px_rgb(29_91_255/0.7)] hover:bg-cta hover:text-white',
      disabled && 'pointer-events-none text-disabled-fg',
    );
    if (disabled) {
      return (
        <span aria-disabled="true" aria-label={label} className={cls}>
          {children}
        </span>
      );
    }
    if (getHref) {
      return (
        <L href={getHref(to)} aria-label={label} aria-current={current ? 'page' : undefined} className={cls}>
          {children}
        </L>
      );
    }
    return (
      <button type="button" onClick={() => onPageChange?.(to)} aria-label={label} aria-current={current ? 'page' : undefined} className={cls}>
        {children}
      </button>
    );
  };

  return (
    <nav aria-label={t.nav} className={cn('flex items-center justify-center', className)}>
      <ul className="flex items-center gap-1">
        <li>
          {item(page - 1, <Icon name="chevron_left" size={20} />, t.previous, false, page <= 1)}
        </li>
        {range(page, pageCount, siblings).map((p, i) =>
          p === 'gap' ? (
            <li key={`g${i}`} aria-hidden className="grid h-10 min-w-6 place-items-center text-sm text-faint max-sm:hidden">
              …
            </li>
          ) : (
            <li key={p} className={cn(p !== page && Math.abs(p - page) > 0 && p !== 1 && p !== pageCount && 'max-sm:hidden')}>
              {item(p, p, t.page(p), p === page)}
            </li>
          ),
        )}
        <li>
          {item(page + 1, <Icon name="chevron_right" size={20} />, t.next, false, page >= pageCount)}
        </li>
      </ul>
    </nav>
  );
}
