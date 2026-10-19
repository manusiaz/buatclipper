'use client';

import * as DialogPrimitive from '@radix-ui/react-dialog';
import type { ComponentProps, ReactNode } from 'react';
import { cn } from '../lib/cn';
import { IconButton } from './button';

export const Dialog = DialogPrimitive.Root;
export const DialogTrigger = DialogPrimitive.Trigger;
export const DialogClose = DialogPrimitive.Close;
export const DialogPortal = DialogPrimitive.Portal;

export function DialogOverlay({ className, ...rest }: ComponentProps<typeof DialogPrimitive.Overlay>) {
  return (
    <DialogPrimitive.Overlay
      className={cn(
        'fixed inset-0 z-50 bg-scrim backdrop-blur-[2px]',
        'data-[state=open]:animate-fade-in data-[state=closed]:animate-fade-out',
        className,
      )}
      {...rest}
    />
  );
}

const SIZES = { sm: 'sm:max-w-[400px]', md: 'sm:max-w-[480px]', lg: 'sm:max-w-[640px]', xl: 'sm:max-w-[800px]' } as const;

export interface DialogContentProps extends Omit<ComponentProps<typeof DialogPrimitive.Content>, 'title'> {
  /** sm 400 · md 480 (DS default) · lg 640 · xl 800. Below 640 px every dialog becomes a bottom sheet (DS 15). */
  size?: keyof typeof SIZES;
  /** Required accessible title (rendered as the header). */
  title: ReactNode;
  description?: ReactNode;
  /** Visually hide the title (still announced). */
  hideTitle?: boolean;
  hideClose?: boolean;
  closeLabel?: string;
  /** Sticky action row (put the cancel button first, primary last: "kanan = maju"). */
  footer?: ReactNode;
  /** Optional element left of the title (e.g. a status icon). */
  icon?: ReactNode;
}

/** Modal dialog (Radix): focus trap, Esc/outside-click close, scroll lock, labelled by title. */
export function DialogContent({
  size = 'md',
  title,
  description,
  hideTitle,
  hideClose,
  closeLabel = 'Tutup',
  footer,
  icon,
  className,
  children,
  ...rest
}: DialogContentProps) {
  return (
    <DialogPortal>
      <DialogOverlay />
      <DialogPrimitive.Content
        className={cn(
          'fixed z-50 flex max-h-[min(92dvh,100%)] w-full flex-col bg-surface text-ink shadow-modal outline-none',
          // mobile: bottom sheet
          'inset-x-0 bottom-0 rounded-t-modal pb-[var(--safe-bottom)] max-sm:data-[state=open]:animate-sheet-up max-sm:data-[state=closed]:animate-sheet-down',
          // ≥ sm: centered modal
          'sm:inset-auto sm:top-1/2 sm:left-1/2 sm:max-h-[min(86dvh,860px)] sm:-translate-x-1/2 sm:-translate-y-1/2 sm:rounded-modal sm:pb-0',
          'sm:data-[state=open]:animate-dialog-in sm:data-[state=closed]:animate-dialog-out',
          SIZES[size],
          className,
        )}
        {...rest}
      >
        <div aria-hidden className="mx-auto mt-2 h-1 w-10 shrink-0 rounded-full bg-border-strong sm:hidden" />
        <div className={cn('flex items-start gap-3 px-5 pt-4 sm:px-6 sm:pt-6', hideTitle && 'sr-only')}>
          {icon ? <div className="shrink-0">{icon}</div> : null}
          <div className="flex min-w-0 flex-1 flex-col gap-1 pr-8">
            <DialogPrimitive.Title className="text-h5 text-ink">{title}</DialogPrimitive.Title>
            {description ? <DialogPrimitive.Description className="text-body-s text-muted">{description}</DialogPrimitive.Description> : null}
          </div>
        </div>
        {!description ? <DialogPrimitive.Description className="sr-only">{typeof title === 'string' ? title : ''}</DialogPrimitive.Description> : null}
        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-5 py-4 sm:px-6">{children}</div>
        {footer ? (
          <div className="flex flex-col-reverse gap-2 border-t border-border px-5 py-4 sm:flex-row sm:justify-end sm:px-6 [&>*]:max-sm:w-full">
            {footer}
          </div>
        ) : null}
        {!hideClose ? (
          <DialogPrimitive.Close asChild>
            <IconButton icon="close" label={closeLabel} size="sm" className="absolute top-3 right-3 sm:top-4 sm:right-4" />
          </DialogPrimitive.Close>
        ) : null}
      </DialogPrimitive.Content>
    </DialogPortal>
  );
}
