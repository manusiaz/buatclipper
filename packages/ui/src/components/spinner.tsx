import { cn } from '../lib/cn';

export interface SpinnerProps {
  size?: number;
  className?: string;
  /** Accessible label; omit when the parent already announces loading (aria-busy). */
  label?: string;
}

/** Circular loading indicator (DS 07 loading state). Keeps spinning under reduced motion (essential feedback). */
export function Spinner({ size = 18, className, label }: SpinnerProps) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      data-motion="essential"
      role={label ? 'status' : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
      className={cn('shrink-0 animate-spin', className)}
    >
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeOpacity="0.25" strokeWidth="3" />
      <path d="M21 12a9 9 0 0 0-9-9" stroke="currentColor" strokeWidth="3" strokeLinecap="round" />
    </svg>
  );
}
