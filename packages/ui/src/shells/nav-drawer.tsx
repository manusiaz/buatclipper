'use client';

import * as DialogPrimitive from '@radix-ui/react-dialog';
import { useState, type MouseEvent, type ReactNode } from 'react';
import { cn } from '../lib/cn';
import { IconButton } from '../components/button';
import { DialogOverlay } from '../components/dialog';

export interface NavDrawerProps {
  /** Pre-rendered navigation (server-rendered links are fine). Clicking any link closes the drawer. */
  children: ReactNode;
  side?: 'left' | 'right';
  /** Element shown in the drawer header (logo). */
  header?: ReactNode;
  /** Bottom area (secondary actions). */
  footer?: ReactNode;
  title: string;
  openLabel?: string;
  closeLabel?: string;
  /** Classes for the trigger button (e.g. "lg:hidden"). */
  triggerClassName?: string;
  /** Hide the drawer panel/overlay from this breakpoint up (e.g. "lg:hidden"). */
  hideFrom?: string;
}

/**
 * Hamburger + side drawer (Radix Dialog: focus trap, Esc, scroll lock). The only client part of the
 * sidebar/public shells, so shells stay server-compatible and accept `linkAs` from server layouts.
 */
export function NavDrawer({
  children,
  side = 'left',
  header,
  footer,
  title,
  openLabel = 'Buka menu',
  closeLabel = 'Tutup menu',
  triggerClassName,
  hideFrom,
}: NavDrawerProps) {
  const [open, setOpen] = useState(false);
  const closeOnLink = (e: MouseEvent<HTMLDivElement>) => {
    const a = (e.target as HTMLElement).closest('a[href]');
    if (a && !e.defaultPrevented && !(e.metaKey || e.ctrlKey || e.shiftKey)) setOpen(false);
  };
  return (
    <DialogPrimitive.Root open={open} onOpenChange={setOpen}>
      <DialogPrimitive.Trigger asChild>
        <IconButton icon="menu" label={openLabel} className={triggerClassName} />
      </DialogPrimitive.Trigger>
      <DialogPrimitive.Portal>
        <DialogOverlay className={hideFrom} />
        <DialogPrimitive.Content
          className={cn(
            'fixed inset-y-0 z-50 flex flex-col bg-surface pt-[var(--safe-top)] pb-[var(--safe-bottom)] shadow-modal outline-none',
            side === 'left'
              ? 'left-0 w-[min(86vw,300px)] rounded-r-modal data-[state=open]:animate-sheet-in-left data-[state=closed]:animate-sheet-out-left'
              : 'right-0 w-[min(88vw,340px)] rounded-l-modal data-[state=open]:animate-sheet-in-right data-[state=closed]:animate-sheet-out-right',
            hideFrom,
          )}
        >
          <DialogPrimitive.Title className="sr-only">{title}</DialogPrimitive.Title>
          <DialogPrimitive.Description className="sr-only">{title}</DialogPrimitive.Description>
          <div className="flex h-16 shrink-0 items-center justify-between pr-3 pl-5">
            {header}
            <DialogPrimitive.Close asChild>
              <IconButton icon="close" label={closeLabel} />
            </DialogPrimitive.Close>
          </div>
          <div className="flex min-h-0 flex-1 flex-col" onClick={closeOnLink}>
            {children}
          </div>
          {footer ? (
            <div className="border-t border-border px-5 py-4" onClick={closeOnLink}>
              {footer}
            </div>
          ) : null}
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}
