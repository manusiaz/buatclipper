'use client';

import * as PopoverPrimitive from '@radix-ui/react-popover';
import type { ComponentProps } from 'react';
import { cn } from '../lib/cn';

export const Popover = PopoverPrimitive.Root;
export const PopoverTrigger = PopoverPrimitive.Trigger;
export const PopoverClose = PopoverPrimitive.Close;
export const PopoverAnchor = PopoverPrimitive.Anchor;

/** Floating panel (r 16, elev 2). For tap-to-explain ⓘ on mobile, filters, quick forms. */
export function PopoverContent({ className, sideOffset = 8, align = 'start', ...rest }: ComponentProps<typeof PopoverPrimitive.Content>) {
  return (
    <PopoverPrimitive.Portal>
      <PopoverPrimitive.Content
        sideOffset={sideOffset}
        align={align}
        collisionPadding={12}
        className={cn(
          'z-50 w-[min(320px,calc(100vw-24px))] rounded-popover border border-border bg-surface p-4 text-ink shadow-pop outline-none',
          'data-[state=open]:animate-pop-in data-[state=closed]:animate-pop-out',
          className,
        )}
        {...rest}
      />
    </PopoverPrimitive.Portal>
  );
}
