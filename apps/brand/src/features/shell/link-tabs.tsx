import Link from 'next/link';
import { cn, type IconName, Icon } from '@clipper/ui';

/** Tab berbasis URL (?tab=…) untuk daftar yang difilter di server. */
export function LinkTabs({ items, label }: { items: { href: string; label: string; active: boolean; icon?: IconName; count?: number }[]; label: string }) {
  return (
    <nav aria-label={label} className="no-scrollbar -mx-1 flex gap-1 overflow-x-auto px-1">
      {items.map((i) => (
        <Link
          key={i.href}
          href={i.href}
          aria-current={i.active ? 'page' : undefined}
          className={cn(
            'inline-flex h-11 shrink-0 items-center gap-2 rounded-full px-4 text-sm font-semibold text-text-2 transition-colors md:h-10 focus-ring',
            'hover:bg-subtle hover:text-ink aria-[current=page]:bg-ink aria-[current=page]:text-surface',
          )}
        >
          {i.icon ? <Icon name={i.icon} size={18} /> : null}
          {i.label}
          {i.count != null ? <span className="tnum text-caption opacity-80">{i.count}</span> : null}
        </Link>
      ))}
    </nav>
  );
}
