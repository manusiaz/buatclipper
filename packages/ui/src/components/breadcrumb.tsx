import type { ElementType } from 'react';
import { cn } from '../lib/cn';
import { Icon } from './icon';

export interface BreadcrumbItem {
  label: string;
  href?: string;
}

export interface BreadcrumbProps {
  items: BreadcrumbItem[];
  linkAs?: ElementType;
  /** On mobile collapse to a single "← parent" back link (DS 15: "Breadcrumb → tombol balik"). Default true. */
  collapseOnMobile?: boolean;
  label?: string;
  className?: string;
}

/** Breadcrumb trail; last item = current page. Server-compatible. */
export function Breadcrumb({ items, linkAs, collapseOnMobile = true, label = 'Breadcrumb', className }: BreadcrumbProps) {
  const L = linkAs ?? 'a';
  const parent = [...items].reverse().find((i, idx) => idx > 0 && i.href);
  return (
    <nav aria-label={label} className={cn('text-body-s', className)}>
      {collapseOnMobile && parent?.href ? (
        <L href={parent.href} className="inline-flex h-11 items-center gap-1 rounded-chip font-semibold text-text-2 hover:text-ink focus-ring sm:hidden">
          <Icon name="arrow_back" size={18} />
          {parent.label}
        </L>
      ) : null}
      <ol className={cn('flex flex-wrap items-center gap-1 text-muted', collapseOnMobile && parent?.href && 'max-sm:hidden')}>
        {items.map((item, i) => {
          const last = i === items.length - 1;
          return (
            <li key={`${item.label}-${i}`} className="inline-flex items-center gap-1">
              {last || !item.href ? (
                <span aria-current={last ? 'page' : undefined} className={cn(last && 'font-semibold text-ink')}>
                  {item.label}
                </span>
              ) : (
                <L href={item.href} className="rounded-tag font-medium text-muted underline-offset-4 hover:text-ink hover:underline focus-ring">
                  {item.label}
                </L>
              )}
              {!last ? <Icon name="chevron_right" size={16} className="text-faint" /> : null}
            </li>
          );
        })}
      </ol>
    </nav>
  );
}
