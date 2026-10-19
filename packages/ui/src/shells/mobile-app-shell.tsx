import type { ElementType, ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Icon } from '../components/icon';
import { Logo } from '../components/logo';
import { badgeText, NavBadge } from './nav-badge';
import type { NavItem } from './types';

export interface MobileAppShellProps {
  /** Bottom navigation, 4 items (DS: Campaign · Tugas · Wallet · Sosmed). */
  nav: NavItem[];
  children: ReactNode;
  /** Left of the top bar. Default <Logo/>. Replaced by `back` + `title` on sub-pages. */
  logo?: ReactNode;
  /** Sub-page title (shows instead of the logo). */
  title?: ReactNode;
  /** Back link for sub-pages: { href, label }. */
  back?: { href: string; label: string };
  /** Right side of the top bar: notification bell, theme toggle… */
  actions?: ReactNode;
  /** Avatar / account menu trigger (rightmost). */
  avatar?: ReactNode;
  /** Full-width strip under the top bar (e.g. "Hubungkan akun sosmed dulu" banner). */
  banner?: ReactNode;
  /** Sticky action above the bottom nav (e.g. "Kirim clip" on detail pages). */
  bottomAction?: ReactNode;
  hideBottomNav?: boolean;
  /** Router link component (e.g. next/link). */
  linkAs?: ElementType;
  navLabel?: string;
  className?: string;
  mainClassName?: string;
}

/**
 * Clipper app shell (mobile-first PWA): glass top bar with safe-area inset, content column max 560 px
 * (centered on desktop), bottom nav with pill active state (DS 10 §9, Android/iOS v2). Server-compatible.
 */
export function MobileAppShell({
  nav,
  children,
  logo,
  title,
  back,
  actions,
  avatar,
  banner,
  bottomAction,
  hideBottomNav,
  linkAs,
  navLabel = 'Navigasi utama',
  className,
  mainClassName,
}: MobileAppShellProps) {
  const L = linkAs ?? 'a';
  return (
    <div className={cn('bg-page flex min-h-dvh flex-col', className)}>
      <header className="sticky top-0 z-30 border-b border-border/70 bg-surface/85 pt-[var(--safe-top)] backdrop-blur-[14px] backdrop-saturate-150">
        <div className="mx-auto flex h-14 w-full max-w-[560px] items-center gap-2 px-4">
          {back ? (
            <L href={back.href} aria-label={back.label} className="touch-target -ml-2 grid size-10 place-items-center rounded-control text-ink hover:bg-subtle focus-ring">
              <Icon name="arrow_back" size={22} />
            </L>
          ) : null}
          <div className="flex min-w-0 flex-1 items-center">
            {title ? <h1 className="truncate text-h6 text-ink">{title}</h1> : (logo ?? <Logo size={28} />)}
          </div>
          {actions ? <div className="flex items-center gap-1">{actions}</div> : null}
          {avatar ? <div className="ml-1 flex items-center">{avatar}</div> : null}
        </div>
      </header>
      {banner ? <div className="mx-auto w-full max-w-[560px] px-4 pt-3">{banner}</div> : null}
      <main
        id="main"
        className={cn(
          'mx-auto w-full max-w-[560px] flex-1 px-4 pt-4',
          hideBottomNav ? 'pb-[calc(24px+var(--safe-bottom))]' : 'pb-[calc(96px+var(--safe-bottom))] md:pb-32',
          bottomAction && 'pb-[calc(168px+var(--safe-bottom))] md:pb-48',
          mainClassName,
        )}
      >
        {children}
      </main>
      {bottomAction ? (
        <div
          className={cn(
            'fixed inset-x-0 z-30 mx-auto w-full max-w-[560px] px-4 pb-2',
            hideBottomNav ? 'bottom-0 pb-[calc(12px+var(--safe-bottom))]' : 'bottom-[calc(68px+var(--safe-bottom))] md:bottom-[92px]',
          )}
        >
          <div className="surface-glass rounded-card p-2 shadow-bar">{bottomAction}</div>
        </div>
      ) : null}
      {!hideBottomNav ? (
        <nav
          aria-label={navLabel}
          className={cn(
            'fixed inset-x-0 bottom-0 z-30 border-t border-border/80 bg-surface/88 pb-[var(--safe-bottom)] backdrop-blur-[18px] backdrop-saturate-150',
            'md:inset-x-auto md:bottom-4 md:left-1/2 md:w-[min(560px,calc(100%-32px))] md:-translate-x-1/2 md:rounded-card md:border md:pb-0 md:shadow-pop',
          )}
        >
          <ul className="mx-auto flex h-[68px] w-full max-w-[560px] items-stretch px-2">
            {nav.map((item) => (
              <li key={item.href} className="flex flex-1">
                <L
                  href={item.href}
                  aria-current={item.active ? 'page' : undefined}
                  aria-label={item.badge ? `${item.label}${badgeText(item.badge)}` : undefined}
                  className="group/nav flex flex-1 flex-col items-center justify-center gap-1 rounded-control text-[11px] font-semibold text-muted transition-colors duration-120 hover:text-ink focus-ring aria-[current=page]:font-bold aria-[current=page]:text-ink"
                >
                  <span
                    className={cn(
                      'relative grid h-8 w-14 place-items-center rounded-full transition-colors duration-220 ease-out',
                      'group-hover/nav:bg-subtle group-aria-[current=page]/nav:bg-primary-soft-hover group-aria-[current=page]/nav:text-primary-soft-fg',
                    )}
                  >
                    {item.icon ? <Icon name={item.icon} size={22} filled={item.active} /> : null}
                    {item.badge ? <NavBadge badge={item.badge} className="absolute -top-0.5 right-2" /> : null}
                  </span>
                  <span className="max-w-full truncate px-1">{item.label}</span>
                </L>
              </li>
            ))}
          </ul>
        </nav>
      ) : null}
    </div>
  );
}
