import Link from 'next/link';
import { cn, Icon, type IconName } from '@clipper/ui';

/** Tab berbasis URL (?tab=…): data tiap tab dibaca di server, jadi bukan Radix Tabs. Gaya = TabsList underline DS. */
export function TabLinks({ tabs, active, label }: { tabs: { href: string; key: string; label: string; icon?: IconName; count?: number }[]; active: string; label: string }) {
  return (
    <nav aria-label={label} className="no-scrollbar mb-5 flex max-w-full gap-1 overflow-x-auto border-b border-border">
      {tabs.map((t) => (
        <Link
          key={t.key}
          href={t.href}
          aria-current={t.key === active ? 'page' : undefined}
          className={cn(
            'relative inline-flex h-11 shrink-0 items-center gap-1.5 rounded-t-[10px] px-3.5 text-sm font-semibold whitespace-nowrap text-muted transition-colors duration-120 focus-ring hover:text-ink',
            "aria-[current=page]:font-bold aria-[current=page]:text-ink aria-[current=page]:after:absolute aria-[current=page]:after:inset-x-2 aria-[current=page]:after:-bottom-px aria-[current=page]:after:h-[3px] aria-[current=page]:after:rounded-full aria-[current=page]:after:bg-primary aria-[current=page]:after:content-['']",
          )}
        >
          {t.icon ? <Icon name={t.icon} size={18} /> : null}
          {t.label}
          {t.count != null ? (
            <span className="grid h-5 min-w-5 place-items-center rounded-full bg-subtle px-1.5 text-[11px] font-bold text-text-2 tnum">{t.count}</span>
          ) : null}
        </Link>
      ))}
    </nav>
  );
}
