import { clsx, type ClassValue } from 'clsx';
import { extendTailwindMerge } from 'tailwind-merge';

/**
 * tailwind-merge that knows the DS scales, so `cn('text-h4', 'text-muted')` keeps both (size vs colour)
 * and `cn('rounded-card', 'rounded-none')` resolves to the last one.
 */
const twMerge = extendTailwindMerge({
  extend: {
    theme: {
      text: ['display', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'body-l', 'body', 'body-s', 'label', 'button', 'caption', 'overline', 'numeric'],
      radius: ['tag', 'chip', 'control', 'card-sm', 'popover', 'card', 'modal', 'media'],
      shadow: ['hairline', 'card', 'card-hover', 'raised', 'pop', 'modal', 'dark', 'blue', 'btn', 'btn-hover', 'btn-pressed', 'btn-ink', 'bar'],
      ease: ['drawer', 'exit'],
    },
  },
});

/** Merge class names (clsx + DS-aware tailwind-merge). */
export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs));
}
