import type { ElementType, ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Icon } from '../components/icon';
import { Logo } from '../components/logo';
import { badgeText, NavBadge } from './nav-badge';
import { NavDrawer } from './nav-drawer';
import type { NavItem, NavSection } from './types';

export interface SidebarShellProps {
  /** Flat items or titled sections. */
  nav: NavItem[] | NavSection[];
  children: ReactNode;
  /** Top of the sidebar. Default <Logo product={product}/>. */
  logo?: ReactNode;
  /** Product label next to the logo ("Brand", "Admin"). */
  product?: ReactNode;
  /** Organisation switcher (brand: pick org; admin: env badge). */
  orgSwitcher?: ReactNode;
  /** User menu trigger (avatar + DropdownMenu) — top-right of the header. */
  userMenu?: ReactNode;
  /** Header actions left of the user menu (search, bell, theme toggle). */
  headerActions?: ReactNode;
  /** Header left content on desktop (e.g. page search or breadcrumb). */
  headerStart?: ReactNode;
  /** Bottom of the sidebar (help link, version). */
  sidebarFooter?: ReactNode;
  /** Full-width banner above the content (e.g. "Org belum terverifikasi"). */
  banner?: ReactNode;
  linkAs?: ElementType;
  labels?: { openMenu?: string; closeMenu?: string; nav?: string };
  className?: string;
  mainClassName?: string;
}

const isSections = (n: NavItem[] | NavSection[]): n is NavSection[] => n.length > 0 && 'items' in (n[0] as object);

function NavList({ sections, L }: { sections: NavSection[]; L: ElementType }) {
  return (
    <div className="flex flex-col gap-5">
      {sections.map((s, si) => (
        <div key={si} className="flex flex-col gap-1">
          {s.title ? <p className="px-3 pb-1 text-[11px] font-bold tracking-[0.14em] text-faint uppercase">{s.title}</p> : null}
          <ul className="flex flex-col gap-0.5">
            {s.items.map((item) => (
              <li key={item.href}>
                <L
                  href={item.href}
                  aria-current={item.active ? 'page' : undefined}
                  target={item.external ? '_blank' : undefined}
                  rel={item.external ? 'noopener noreferrer' : undefined}
                  aria-label={item.badge ? `${item.label}${badgeText(item.badge)}` : undefined}
                  className={cn(
                    'group/item flex h-11 items-center gap-3 rounded-[10px] px-3 text-sm font-semibold text-text-2 transition-colors duration-120 md:h-10',
                    'hover:bg-subtle hover:text-ink focus-ring',
                    'aria-[current=page]:bg-brand-50 aria-[current=page]:font-bold aria-[current=page]:text-primary-soft-fg aria-[current=page]:shadow-[inset_3px_0_0_var(--color-primary)]',
                    'dark:aria-[current=page]:bg-primary-soft',
                  )}
                >
                  {item.icon ? (
                    <Icon name={item.icon} size={20} filled={item.active} className="text-muted group-hover/item:text-ink group-aria-[current=page]/item:text-primary-soft-fg" />
                  ) : null}
                  <span className="min-w-0 flex-1 truncate">{item.label}</span>
                  {item.badge ? <NavBadge badge={item.badge} /> : null}
                  {item.external ? <Icon name="open_in_new" size={16} className="text-faint" /> : null}
                </L>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </div>
  );
}

/**
 * Brand/admin shell: fixed sidebar ≥ 1024 px, drawer below; sticky glass header with org switcher,
 * actions and user menu. No routing logic — `active` comes from the app. Server-compatible
 * (the drawer is a client island), so `linkAs={Link}` works from server layouts.
 */
export function SidebarShell({
  nav,
  children,
  logo,
  product,
  orgSwitcher,
  userMenu,
  headerActions,
  headerStart,
  sidebarFooter,
  banner,
  linkAs,
  labels,
  className,
  mainClassName,
}: SidebarShellProps) {
  const L = linkAs ?? 'a';
  const sections: NavSection[] = isSections(nav) ? nav : [{ items: nav as NavItem[] }];
  const t = { openMenu: 'Buka menu', closeMenu: 'Tutup menu', nav: 'Navigasi utama', ...labels };
  const brand = logo ?? <Logo size={28} product={product} />;

  const sidebarBody = (
    <>
      {orgSwitcher ? <div className="px-3 pb-3">{orgSwitcher}</div> : null}
      <nav aria-label={t.nav} className="min-h-0 flex-1 overflow-y-auto px-3 pb-4">
        <NavList sections={sections} L={L} />
      </nav>
      {sidebarFooter ? <div className="border-t border-border px-3 py-3">{sidebarFooter}</div> : null}
    </>
  );

  return (
    <div className={cn('bg-page min-h-dvh', className)}>
      {/* Desktop sidebar */}
      <aside className="fixed inset-y-0 left-0 z-30 hidden w-[264px] flex-col border-r border-border bg-surface/90 backdrop-blur-[14px] lg:flex">
        <div className="flex h-16 shrink-0 items-center px-5">{brand}</div>
        {sidebarBody}
      </aside>

      <div className="flex min-h-dvh flex-col lg:pl-[264px]">
        <header className="sticky top-0 z-20 border-b border-border/70 bg-surface/85 pt-[var(--safe-top)] backdrop-blur-[14px] backdrop-saturate-150">
          <div className="flex h-16 items-center gap-2 px-4 md:px-6 lg:px-8">
            <NavDrawer title={t.nav} header={brand} openLabel={t.openMenu} closeLabel={t.closeMenu} triggerClassName="-ml-1 lg:hidden" hideFrom="lg:hidden">
              {sidebarBody}
            </NavDrawer>
            <div className="flex min-w-0 items-center lg:hidden">{brand}</div>
            <div className="hidden min-w-0 flex-1 items-center lg:flex">{headerStart}</div>
            <div className="ml-auto flex items-center gap-1">
              {headerActions}
              {userMenu ? <div className="ml-1">{userMenu}</div> : null}
            </div>
          </div>
        </header>
        {banner ? <div className="px-4 pt-4 md:px-6 lg:px-8">{banner}</div> : null}
        <main id="main" className={cn('mx-auto w-full max-w-[1280px] flex-1 px-4 py-5 md:px-6 md:py-6 lg:px-8', mainClassName)}>
          {children}
        </main>
      </div>
    </div>
  );
}
