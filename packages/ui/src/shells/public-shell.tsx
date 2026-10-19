'use client';

import * as DialogPrimitive from '@radix-ui/react-dialog';
import { useState, type ElementType, type ReactNode } from 'react';
import { cn } from '../lib/cn';
import { IconButton } from '../components/button';
import { Container } from '../components/layout';
import { DialogOverlay } from '../components/dialog';
import { Icon } from '../components/icon';
import { Logo } from '../components/logo';
import { useLinkComponent } from './link-context';
import type { FooterColumn, NavItem } from './types';

export interface PublicShellProps {
  /** ≤ 5 main links (DS 10). */
  nav: NavItem[];
  children: ReactNode;
  logo?: ReactNode;
  /** Header primary CTA (one, right) — stays visible on mobile (DS 10 do/don't). */
  cta?: ReactNode;
  /** Secondary header action, e.g. "Masuk" text button (hidden on small phones, shown in the menu). */
  secondaryAction?: ReactNode;
  /** Header right extras (theme toggle, language). */
  headerExtras?: ReactNode;
  footer?: {
    columns: FooterColumn[];
    tagline?: ReactNode;
    /** Social / app-store links row. */
    social?: ReactNode;
    /** Copyright + legal line. */
    bottom?: ReactNode;
  };
  /** Announcement strip above the header. */
  announcement?: ReactNode;
  linkAs?: ElementType;
  labels?: { openMenu?: string; closeMenu?: string; nav?: string; footer?: string };
  className?: string;
}

/** Marketing site shell: sticky glass header (64 px), mobile drawer, ink footer with 4 link columns. */
export function PublicShell({
  nav,
  children,
  logo,
  cta,
  secondaryAction,
  headerExtras,
  footer,
  announcement,
  linkAs,
  labels,
  className,
}: PublicShellProps) {
  const L = useLinkComponent(linkAs);
  const [open, setOpen] = useState(false);
  const t = { openMenu: 'Buka menu', closeMenu: 'Tutup menu', nav: 'Navigasi utama', footer: 'Footer', ...labels };
  const brand = logo ?? <Logo size={30} href="/" linkAs={L} />;

  return (
    <div className={cn('bg-page flex min-h-dvh flex-col', className)}>
      {announcement ? <div className="bg-navy px-4 py-2 text-center text-caption font-semibold text-white">{announcement}</div> : null}
      <header className="sticky top-0 z-30 border-b border-border/60 bg-surface/88 pt-[var(--safe-top)] backdrop-blur-[14px] backdrop-saturate-150">
        <Container className="flex h-16 items-center gap-3">
          <div className="flex shrink-0 items-center">{brand}</div>
          <nav aria-label={t.nav} className="mx-auto hidden md:block">
            <ul className="flex items-center gap-1">
              {nav.map((item) => (
                <li key={item.href}>
                  <L
                    href={item.href}
                    aria-current={item.active ? 'page' : undefined}
                    className={cn(
                      'inline-flex h-10 items-center gap-1.5 rounded-full px-3.5 text-sm font-semibold text-text-2 transition-colors duration-120',
                      'hover:bg-subtle hover:text-ink focus-ring aria-[current=page]:bg-primary-soft aria-[current=page]:font-bold aria-[current=page]:text-ink',
                    )}
                  >
                    {item.label}
                  </L>
                </li>
              ))}
            </ul>
          </nav>
          <div className="ml-auto flex items-center gap-2 md:ml-0">
            {headerExtras ? <div className="hidden items-center gap-1 sm:flex">{headerExtras}</div> : null}
            {secondaryAction ? <div className="hidden sm:block">{secondaryAction}</div> : null}
            {cta}
            <IconButton icon="menu" label={t.openMenu} onClick={() => setOpen(true)} className="md:hidden" />
          </div>
        </Container>
      </header>

      <DialogPrimitive.Root open={open} onOpenChange={setOpen}>
        <DialogPrimitive.Portal>
          <DialogOverlay className="md:hidden" />
          <DialogPrimitive.Content
            className={cn(
              'fixed inset-y-0 right-0 z-50 flex w-[min(88vw,340px)] flex-col rounded-l-modal bg-surface pt-[var(--safe-top)] pb-[var(--safe-bottom)] shadow-modal outline-none md:hidden',
              'data-[state=open]:animate-sheet-in-right data-[state=closed]:animate-sheet-out-right',
            )}
          >
            <DialogPrimitive.Title className="sr-only">{t.nav}</DialogPrimitive.Title>
            <DialogPrimitive.Description className="sr-only">{t.nav}</DialogPrimitive.Description>
            <div className="flex h-16 shrink-0 items-center justify-between pr-3 pl-5">
              {logo ?? <Logo size={28} />}
              <DialogPrimitive.Close asChild>
                <IconButton icon="close" label={t.closeMenu} />
              </DialogPrimitive.Close>
            </div>
            <nav aria-label={t.nav} className="flex-1 overflow-y-auto px-3 py-2">
              <ul className="flex flex-col gap-1">
                {nav.map((item) => (
                  <li key={item.href}>
                    <L
                      href={item.href}
                      onClick={() => setOpen(false)}
                      aria-current={item.active ? 'page' : undefined}
                      className="flex h-12 items-center gap-3 rounded-control px-3 text-body font-semibold text-text-2 hover:bg-subtle hover:text-ink focus-ring aria-[current=page]:bg-primary-soft aria-[current=page]:font-bold aria-[current=page]:text-ink"
                    >
                      {item.icon ? <Icon name={item.icon} size={22} className="text-muted" /> : null}
                      <span className="flex-1">{item.label}</span>
                      <Icon name="chevron_right" size={20} className="text-faint" />
                    </L>
                  </li>
                ))}
              </ul>
            </nav>
            {secondaryAction || headerExtras ? (
              <div className="flex flex-col gap-3 border-t border-border px-5 py-4">
                {headerExtras ? <div className="flex items-center gap-2">{headerExtras}</div> : null}
                {secondaryAction ? <div className="[&>*]:w-full">{secondaryAction}</div> : null}
              </div>
            ) : null}
          </DialogPrimitive.Content>
        </DialogPrimitive.Portal>
      </DialogPrimitive.Root>

      <main id="main" className="flex-1">
        {children}
      </main>

      {footer ? (
        <footer aria-label={t.footer} className="surface-dark rounded-none shadow-none">
          <Container className="flex flex-col gap-10 py-12 md:py-16">
            <div className="grid gap-10 lg:grid-cols-[1.2fr_2fr]">
              <div className="flex max-w-[34ch] flex-col gap-4">
                <Logo size={30} variant="on-dark" />
                {footer.tagline ? <p className="text-body-s text-white/70">{footer.tagline}</p> : null}
                {footer.social ? <div className="flex items-center gap-2">{footer.social}</div> : null}
              </div>
              <div className="grid grid-cols-2 gap-8 sm:grid-cols-4">
                {footer.columns.map((col) => (
                  <div key={col.title} className="flex flex-col gap-3">
                    <p className="text-[11px] font-bold tracking-[0.14em] text-brand-300 uppercase">{col.title}</p>
                    <ul className="flex flex-col gap-1">
                      {col.links.map((l) => (
                        <li key={l.href + l.label}>
                          <L
                            href={l.href}
                            target={l.external ? '_blank' : undefined}
                            rel={l.external ? 'noopener noreferrer' : undefined}
                            className="inline-flex min-h-8 items-center rounded-tag text-sm text-white/75 underline-offset-4 hover:text-white hover:underline focus-ring"
                          >
                            {l.label}
                          </L>
                        </li>
                      ))}
                    </ul>
                  </div>
                ))}
              </div>
            </div>
            {footer.bottom ? <div className="border-t border-white/10 pt-6 text-caption text-white/60">{footer.bottom}</div> : null}
          </Container>
        </footer>
      ) : null}
    </div>
  );
}
