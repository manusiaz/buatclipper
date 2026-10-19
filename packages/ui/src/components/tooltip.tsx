'use client';

import * as TooltipPrimitive from '@radix-ui/react-tooltip';
import type { ReactNode } from 'react';
import { cn } from '../lib/cn';

export const TooltipProvider = TooltipPrimitive.Provider;

export interface TooltipProps {
  /** Tooltip text (supplementary only — never the only place for essential info, DS 12 §4). */
  content: ReactNode;
  /** A single focusable element (button, link, IconButton). */
  children: ReactNode;
  side?: 'top' | 'right' | 'bottom' | 'left';
  align?: 'start' | 'center' | 'end';
  /** Hover delay. DS: 300 ms. */
  delayDuration?: number;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  className?: string;
}

/** Ink tooltip with arrow. Shows on hover (300 ms) and keyboard focus, hides on Esc. */
export function Tooltip({ content, children, side = 'top', align = 'center', delayDuration = 300, open, onOpenChange, className }: TooltipProps) {
  return (
    <TooltipPrimitive.Provider delayDuration={delayDuration} skipDelayDuration={200}>
      <TooltipPrimitive.Root open={open} onOpenChange={onOpenChange}>
        <TooltipPrimitive.Trigger asChild>{children}</TooltipPrimitive.Trigger>
        <TooltipPrimitive.Portal>
          <TooltipPrimitive.Content
            side={side}
            align={align}
            sideOffset={8}
            collisionPadding={12}
            className={cn(
              'z-[60] max-w-[240px] rounded-chip bg-inverse px-3 py-2 text-caption font-medium text-inverse-fg shadow-pop',
              'data-[state=delayed-open]:animate-pop-in data-[state=instant-open]:animate-pop-in data-[state=closed]:animate-pop-out',
              className,
            )}
          >
            {content}
            <TooltipPrimitive.Arrow className="fill-inverse" width={12} height={6} />
          </TooltipPrimitive.Content>
        </TooltipPrimitive.Portal>
      </TooltipPrimitive.Root>
    </TooltipPrimitive.Provider>
  );
}
