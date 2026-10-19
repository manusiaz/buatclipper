import type { ElementType, HTMLAttributes, ReactNode } from 'react';
import { cva } from 'class-variance-authority';
import { cn } from '../lib/cn';

/* ds-notes surface styles: CARD / raised / DARK / BLUE / GLASS (+ tint & outline from DS 09 §5). */
export const cardVariants = cva('relative isolate text-ink', {
  variants: {
    variant: {
      default: 'surface-card rounded-card',
      raised: 'surface-raised rounded-card',
      dark: 'surface-dark rounded-card text-white',
      blue: 'surface-blue rounded-card text-white',
      glass: 'surface-glass rounded-card shadow-card',
      tint: 'rounded-card-sm bg-primary-soft',
      outline: 'rounded-card-sm border-[1.5px] border-border-strong bg-surface',
    },
    padding: {
      none: '',
      sm: 'p-3',
      md: 'p-4 md:p-5',
      lg: 'p-5 md:p-6',
    },
    interactive: {
      true: [
        'transition-[transform,box-shadow] duration-220 ease-out focus-ring-within',
        'hover:shadow-card-hover motion-safe:hover:-translate-y-0.5 active:translate-y-0',
      ],
      false: '',
    },
  },
  defaultVariants: { variant: 'default', padding: 'md', interactive: false },
});

export type CardVariant = 'default' | 'raised' | 'dark' | 'blue' | 'glass' | 'tint' | 'outline';

export interface CardProps extends HTMLAttributes<HTMLElement> {
  variant?: CardVariant;
  padding?: 'none' | 'sm' | 'md' | 'lg';
  /** Hover lift + stronger shadow; ring when a child link/button has keyboard focus. */
  interactive?: boolean;
  /** Element to render (div default; use "section", "article", "li"…). */
  as?: ElementType;
  children?: ReactNode;
}

/** Surface container. Server-compatible. */
export function Card({ variant = 'default', padding = 'md', interactive = false, as: Comp = 'div', className, children, ...rest }: CardProps) {
  return (
    <Comp className={cn(cardVariants({ variant, padding, interactive }), className)} {...rest}>
      {children}
    </Comp>
  );
}

export function CardHeader({ className, children, actions, ...rest }: HTMLAttributes<HTMLDivElement> & { actions?: ReactNode }) {
  return (
    <div className={cn('mb-4 flex items-start justify-between gap-3', className)} {...rest}>
      <div className="flex min-w-0 flex-col gap-1">{children}</div>
      {actions ? <div className="flex shrink-0 items-center gap-2">{actions}</div> : null}
    </div>
  );
}

export function CardTitle({ as: Comp = 'h3', className, ...rest }: HTMLAttributes<HTMLHeadingElement> & { as?: ElementType }) {
  return <Comp className={cn('text-h5', className)} {...rest} />;
}

export function CardDescription({ className, ...rest }: HTMLAttributes<HTMLParagraphElement>) {
  return <p className={cn('text-body-s text-muted', className)} {...rest} />;
}

export function CardContent({ className, ...rest }: HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('flex flex-col gap-3', className)} {...rest} />;
}

export function CardFooter({ className, ...rest }: HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('mt-4 flex flex-wrap items-center gap-2 border-t border-border pt-4', className)} {...rest} />;
}
