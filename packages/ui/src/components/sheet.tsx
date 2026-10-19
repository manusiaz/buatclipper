'use client';

import * as DialogPrimitive from '@radix-ui/react-dialog';
import type { ComponentProps, ReactNode } from 'react';
import { cn } from '../lib/cn';
import { IconButton } from './button';
import { DialogOverlay } from './dialog';

export const Sheet = DialogPrimitive.Root;
export const SheetTrigger = DialogPrimitive.Trigger;
export const SheetClose = DialogPrimitive.Close;

export interface SheetContentProps extends Omit<ComponentProps<typeof DialogPrimitive.Content>, 'title'> {
  /**
   * `auto` (default): bottom sheet on mobile, right side sheet from 768 px (DS 12: filter → bottom sheet).
   * Or force `bottom`, `right`, `left` (navigation drawer).
   */
  side?: 'auto' | 'bottom' | 'right' | 'left';
  /** Side-sheet width ≥ md: sm 360 · md 440 · lg 560. */
  size?: 'sm' | 'md' | 'lg';
  title: ReactNode;
  description?: ReactNode;
  hideTitle?: boolean;
  hideClose?: boolean;
  closeLabel?: string;
  /** Sticky bottom action row, e.g. "Tampilkan 39 hasil". */
  footer?: ReactNode;
  /** Replaces the default header (title still required for a11y; it becomes visually hidden). */
  header?: ReactNode;
}

const WIDTH = { sm: 'md:w-[360px]', md: 'md:w-[440px]', lg: 'md:w-[560px]' } as const;

export function SheetContent({
  side = 'auto',
  size = 'md',
  title,
  description,
  hideTitle,
  hideClose,
  closeLabel = 'Tutup',
  footer,
  header,
  className,
  children,
  ...rest
}: SheetContentProps) {
  const bottom = 'inset-x-0 bottom-0 max-h-[90dvh] rounded-t-modal pb-[var(--safe-bottom)] data-[state=open]:animate-sheet-up data-[state=closed]:animate-sheet-down';
  const right =
    'inset-y-0 right-0 h-dvh w-[min(88vw,440px)] rounded-l-modal pt-[var(--safe-top)] pb-[var(--safe-bottom)] data-[state=open]:animate-sheet-in-right data-[state=closed]:animate-sheet-out-right';
  const left =
    'inset-y-0 left-0 h-dvh w-[min(86vw,320px)] rounded-r-modal pt-[var(--safe-top)] pb-[var(--safe-bottom)] data-[state=open]:animate-sheet-in-left data-[state=closed]:animate-sheet-out-left';
  const auto = cn(
    'max-md:inset-x-0 max-md:bottom-0 max-md:max-h-[90dvh] max-md:rounded-t-modal max-md:pb-[var(--safe-bottom)]',
    'max-md:data-[state=open]:animate-sheet-up max-md:data-[state=closed]:animate-sheet-down',
    'md:inset-y-0 md:right-0 md:h-dvh md:rounded-l-modal md:data-[state=open]:animate-sheet-in-right md:data-[state=closed]:animate-sheet-out-right',
    WIDTH[size],
  );
  const isBottomish = side === 'bottom' || side === 'auto';
  return (
    <DialogPrimitive.Portal>
      <DialogOverlay />
      <DialogPrimitive.Content
        className={cn(
          'fixed z-50 flex flex-col bg-surface text-ink shadow-modal outline-none',
          side === 'bottom' ? bottom : side === 'right' ? cn(right, WIDTH[size]) : side === 'left' ? left : auto,
          className,
        )}
        {...rest}
      >
        {isBottomish ? <div aria-hidden className={cn('mx-auto mt-2 h-1 w-10 shrink-0 rounded-full bg-border-strong', side === 'auto' && 'md:hidden')} /> : null}
        {header ? <div className="shrink-0">{header}</div> : null}
        <div className={cn('flex shrink-0 items-start gap-3 px-5 pt-4 pb-2', (hideTitle || header) && 'sr-only')}>
          <div className="flex min-w-0 flex-1 flex-col gap-1 pr-8">
            <DialogPrimitive.Title className="text-h6 text-ink">{title}</DialogPrimitive.Title>
            {description ? <DialogPrimitive.Description className="text-body-s text-muted">{description}</DialogPrimitive.Description> : null}
          </div>
        </div>
        {!description ? <DialogPrimitive.Description className="sr-only">{typeof title === 'string' ? title : ''}</DialogPrimitive.Description> : null}
        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-5 py-3">{children}</div>
        {footer ? <div className="flex shrink-0 gap-2 border-t border-border bg-surface px-5 py-3 [&>*]:flex-1">{footer}</div> : null}
        {!hideClose ? (
          <DialogPrimitive.Close asChild>
            <IconButton icon="close" label={closeLabel} size="sm" className={cn('absolute right-3', isBottomish ? 'top-4' : 'top-[calc(var(--safe-top)+12px)]')} />
          </DialogPrimitive.Close>
        ) : null}
      </DialogPrimitive.Content>
    </DialogPrimitive.Portal>
  );
}
