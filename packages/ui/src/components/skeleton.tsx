import type { HTMLAttributes } from 'react';
import { cn } from '../lib/cn';

export interface SkeletonProps extends HTMLAttributes<HTMLDivElement> {
  /** `text` lines, `circle` avatar, `rect` media/card. */
  shape?: 'rect' | 'text' | 'circle';
}

/** Shimmer placeholder (DS 12 §5). Decorative: wrap the loading region with aria-busy="true". */
export function Skeleton({ shape = 'rect', className, ...rest }: SkeletonProps) {
  return (
    <div
      aria-hidden
      className={cn(
        'skeleton-shimmer animate-shimmer',
        shape === 'circle' ? 'rounded-full' : shape === 'text' ? 'h-3.5 rounded-full' : 'rounded-card-sm',
        className,
      )}
      {...rest}
    />
  );
}

/** Ready-made skeleton matching CampaignCard's footprint. */
export function CampaignCardSkeleton({ className }: { className?: string }) {
  return (
    <div aria-hidden className={cn('surface-card overflow-hidden rounded-card', className)}>
      <Skeleton className="aspect-[16/10] w-full rounded-none" />
      <div className="flex flex-col gap-3 p-3.5">
        <Skeleton shape="text" className="w-2/5" />
        <Skeleton shape="text" className="h-4 w-4/5" />
        <Skeleton shape="text" className="h-6 w-1/2" />
        <Skeleton shape="text" className="h-1.5 w-full" />
        <Skeleton className="h-11 w-full rounded-control" />
      </div>
    </div>
  );
}
