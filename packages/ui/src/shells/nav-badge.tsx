import { cn } from '../lib/cn';

/** Small count/dot badge used by shells' nav items. */
export function NavBadge({ badge, className }: { badge: number | boolean | string; className?: string }) {
  if (badge === false || badge === 0 || badge === '') return null;
  if (badge === true) return <span aria-hidden className={cn('size-2 rounded-full bg-danger ring-2 ring-surface', className)} />;
  return (
    <span
      className={cn(
        'grid h-[18px] min-w-[18px] place-items-center rounded-full bg-danger px-1 text-[10px] leading-none font-extrabold text-white tnum',
        className,
      )}
    >
      {typeof badge === 'number' && badge > 99 ? '99+' : badge}
    </span>
  );
}

export function badgeText(badge: NavBadgeValue | undefined): string {
  if (badge === undefined || badge === false || badge === 0 || badge === '') return '';
  if (badge === true) return ' (baru)';
  return ` (${badge})`;
}

type NavBadgeValue = number | boolean | string;
