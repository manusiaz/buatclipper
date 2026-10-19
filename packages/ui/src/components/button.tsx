import type { AnchorHTMLAttributes, ButtonHTMLAttributes, ElementType, ReactNode, Ref } from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '../lib/cn';
import { Icon, type IconName } from './icon';
import { Spinner } from './spinner';

/*
 * DS 07 Buttons: primary (blue gradient, 1 per screen) · secondary (outline) · tertiary (blue tint) ·
 * ghost/text · ink (financial) · danger (soft red) · link. Sizes sm 32 · md 40 (44 on touch) · lg 48.
 * States: default / hover / pressed (scale .97) / focus-visible ring / disabled / loading.
 */
export const buttonVariants = cva(
  [
    'relative inline-flex shrink-0 select-none items-center justify-center gap-2 whitespace-nowrap font-bold',
    'transition-[background-color,background-image,box-shadow,color,border-color,transform] duration-120 ease-out',
    'focus-ring active:scale-[0.97] motion-reduce:active:scale-100',
    'disabled:pointer-events-none aria-disabled:pointer-events-none',
  ],
  {
    variants: {
      variant: {
        primary: [
          'bg-cta text-white shadow-btn',
          'hover:bg-cta-hover hover:shadow-btn-hover',
          'active:bg-none active:bg-primary-pressed active:shadow-btn-pressed',
          'disabled:bg-none disabled:bg-subtle disabled:text-disabled-fg disabled:shadow-none',
          'aria-disabled:bg-none aria-disabled:bg-subtle aria-disabled:text-disabled-fg aria-disabled:shadow-none',
        ],
        secondary: [
          'border border-border-strong bg-surface text-ink shadow-hairline',
          'hover:border-border-hover hover:bg-surface-2 hover:shadow-[0_6px_14px_-8px_rgb(16_40_110/0.3)]',
          'active:bg-subtle active:shadow-none',
          'disabled:border-border disabled:text-disabled-fg disabled:shadow-none',
          'aria-disabled:border-border aria-disabled:text-disabled-fg aria-disabled:shadow-none',
        ],
        tertiary: [
          'bg-primary-soft text-primary-soft-fg',
          'hover:bg-primary-soft-hover active:bg-primary-soft-pressed',
          'disabled:bg-disabled disabled:text-disabled-fg aria-disabled:bg-disabled aria-disabled:text-disabled-fg',
        ],
        ghost: [
          'bg-transparent text-link',
          'hover:bg-brand-50 hover:text-primary-soft-fg active:bg-primary-soft dark:hover:bg-primary-soft',
          'disabled:text-disabled-fg aria-disabled:text-disabled-fg',
        ],
        ink: [
          'bg-cta-ink text-white shadow-btn-ink',
          'hover:brightness-125 active:brightness-100',
          'disabled:bg-none disabled:bg-subtle disabled:text-disabled-fg disabled:shadow-none',
          'aria-disabled:bg-none aria-disabled:bg-subtle aria-disabled:text-disabled-fg aria-disabled:shadow-none',
        ],
        danger: [
          'border border-danger-border bg-danger-bg text-danger-fg',
          'hover:border-danger hover:bg-[color-mix(in_oklab,var(--color-danger-bg),var(--color-danger)_10%)]',
          'active:bg-[color-mix(in_oklab,var(--color-danger-bg),var(--color-danger)_18%)]',
          'disabled:border-border disabled:bg-disabled disabled:text-disabled-fg',
          'aria-disabled:border-border aria-disabled:bg-disabled aria-disabled:text-disabled-fg',
        ],
        link: [
          'h-auto! gap-1 rounded-tag! px-0! py-0 text-link underline-offset-4 hover:underline',
          'active:scale-100 disabled:text-disabled-fg aria-disabled:text-disabled-fg',
        ],
      },
      size: {
        sm: 'h-8 rounded-[10px] px-3 text-[13px] touch-target',
        md: 'h-11 rounded-control px-4 text-sm md:h-10',
        lg: 'h-12 rounded-control px-5 text-button',
      },
      fullWidth: { true: 'w-full', false: '' },
    },
    defaultVariants: { variant: 'primary', size: 'md', fullWidth: false },
  },
);

const ICON_SIZE = { sm: 16, md: 18, lg: 20 } as const;

export type ButtonVariant = NonNullable<VariantProps<typeof buttonVariants>['variant']>;
export type ButtonSize = NonNullable<VariantProps<typeof buttonVariants>['size']>;

interface ButtonOwnProps {
  variant?: ButtonVariant;
  size?: ButtonSize;
  fullWidth?: boolean;
  /** Shows a spinner, sets aria-busy and blocks clicks. Label stays (DS: width must not jump). */
  loading?: boolean;
  /** Optional text announced/shown while loading, e.g. "Mengirim…". */
  loadingText?: ReactNode;
  /** Material Symbols name or any node, placed before the label (DS: 20 px, gap 8). */
  iconLeft?: IconName | ReactNode;
  iconRight?: IconName | ReactNode;
  /** Count badge inside the button (DS 07 anatomy #4). */
  badge?: ReactNode;
  className?: string;
  children?: ReactNode;
}

export type ButtonAsButtonProps = ButtonOwnProps &
  Omit<ButtonHTMLAttributes<HTMLButtonElement>, keyof ButtonOwnProps> & {
    href?: undefined;
    ref?: Ref<HTMLButtonElement>;
  };

export type ButtonAsLinkProps = ButtonOwnProps &
  Omit<AnchorHTMLAttributes<HTMLAnchorElement>, keyof ButtonOwnProps> & {
    /** Renders an anchor (or `linkAs`) instead of a <button>. */
    href: string;
    /** Link component, e.g. `next/link`'s Link. Default <a>. */
    linkAs?: ElementType;
    /** Opens in a new tab with rel="noopener noreferrer" and an external icon. */
    external?: boolean;
    disabled?: boolean;
    ref?: Ref<HTMLAnchorElement>;
  };

export type ButtonProps = ButtonAsButtonProps | ButtonAsLinkProps;

function renderIcon(icon: IconName | ReactNode, size: number) {
  if (icon == null || icon === false) return null;
  return typeof icon === 'string' ? <Icon name={icon as IconName} size={size} /> : icon;
}

/** DS button. `href` → <a>/linkAs. Server-compatible (no hooks). */
export function Button(props: ButtonProps) {
  const {
    variant = 'primary',
    size = 'md',
    fullWidth,
    loading = false,
    loadingText,
    iconLeft,
    iconRight,
    badge,
    className,
    children,
  } = props;
  const iconSize = ICON_SIZE[size];
  const classes = cn(buttonVariants({ variant, size, fullWidth }), loading && 'cursor-progress', className);
  const content = (
    <>
      {loading ? <Spinner size={iconSize} /> : renderIcon(iconLeft, iconSize)}
      {loading && loadingText ? <span>{loadingText}</span> : children != null ? <span className="truncate">{children}</span> : null}
      {badge != null ? (
        <span
          className={cn(
            'grid h-5 min-w-5 place-items-center rounded-full px-1.5 text-[11px] font-extrabold tnum',
            variant === 'primary' || variant === 'ink' ? 'bg-white/25 text-white' : 'bg-primary text-white',
          )}
        >
          {badge}
        </span>
      ) : null}
      {renderIcon(iconRight, iconSize)}
    </>
  );

  if (props.href !== undefined) {
    const {
      href,
      linkAs,
      external,
      disabled,
      variant: _v,
      size: _s,
      fullWidth: _f,
      loading: _l,
      loadingText: _lt,
      iconLeft: _il,
      iconRight: _ir,
      badge: _b,
      className: _c,
      children: _ch,
      ...anchorRest
    } = props;
    const Comp = linkAs ?? 'a';
    const inert = disabled || loading;
    return (
      <Comp
        {...anchorRest}
        href={inert ? undefined : href}
        aria-disabled={inert || undefined}
        aria-busy={loading || undefined}
        tabIndex={inert ? -1 : anchorRest.tabIndex}
        target={external ? '_blank' : anchorRest.target}
        rel={external ? 'noopener noreferrer' : anchorRest.rel}
        className={classes}
      >
        {content}
        {external && !iconRight ? <Icon name="open_in_new" size={iconSize - 2} /> : null}
      </Comp>
    );
  }

  const {
    variant: _v,
    size: _s,
    fullWidth: _f,
    loading: _l,
    loadingText: _lt,
    iconLeft: _il,
    iconRight: _ir,
    badge: _b,
    className: _c,
    children: _ch,
    disabled,
    type = 'button',
    href: _h,
    ...buttonRest
  } = props;
  return (
    <button
      {...buttonRest}
      type={type}
      disabled={disabled}
      aria-disabled={loading || undefined}
      aria-busy={loading || undefined}
      onClick={loading ? undefined : buttonRest.onClick}
      className={classes}
    >
      {content}
    </button>
  );
}

/* ───────────────────────── IconButton ───────────────────────── */

export const iconButtonVariants = cva(
  [
    'relative inline-grid shrink-0 select-none place-items-center touch-target',
    'transition-[background-color,box-shadow,color,border-color,transform] duration-120 ease-out',
    'focus-ring active:scale-[0.94] motion-reduce:active:scale-100',
    'disabled:pointer-events-none disabled:opacity-45 aria-disabled:pointer-events-none aria-disabled:opacity-45',
  ],
  {
    variants: {
      variant: {
        primary: 'bg-cta text-white shadow-btn hover:bg-cta-hover hover:shadow-btn-hover active:bg-none active:bg-primary-pressed',
        secondary: 'border border-border-strong bg-surface text-ink shadow-hairline hover:border-border-hover hover:bg-surface-2 active:bg-subtle',
        tertiary: 'bg-primary-soft text-primary-soft-fg hover:bg-primary-soft-hover active:bg-primary-soft-pressed',
        ghost: 'bg-transparent text-text-2 hover:bg-subtle hover:text-ink active:bg-border',
        glass: 'surface-glass text-ink shadow-hairline hover:bg-white/90 dark:hover:bg-surface',
        'glass-dark': 'surface-glass-dark hover:bg-navy/75',
        danger: 'border border-danger-border bg-danger-bg text-danger-fg hover:border-danger',
      },
      size: {
        sm: 'size-8 rounded-[10px]',
        md: 'size-10 rounded-control',
        lg: 'size-12 rounded-control',
      },
      shape: { square: '', round: 'rounded-full' },
    },
    defaultVariants: { variant: 'ghost', size: 'md', shape: 'square' },
  },
);

export interface IconButtonProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'children'> {
  icon: IconName;
  /** Required accessible name (DS: "Icon only — wajib aria-label"). Also used as tooltip title. */
  label: string;
  variant?: NonNullable<VariantProps<typeof iconButtonVariants>['variant']>;
  size?: 'sm' | 'md' | 'lg';
  shape?: 'square' | 'round';
  filled?: boolean;
  loading?: boolean;
  /** Dot (true) or count badge (number) on the top-right corner, e.g. notifications. */
  badge?: boolean | number;
  /** Renders an anchor instead of a button. */
  href?: string;
  linkAs?: ElementType;
  ref?: Ref<HTMLButtonElement>;
}

/** Icon-only button with an accessible name and ≥ 44 px touch area. Server-compatible. */
export function IconButton({
  icon,
  label,
  variant,
  size = 'md',
  shape,
  filled,
  loading,
  badge,
  href,
  linkAs,
  className,
  type = 'button',
  ref,
  ...rest
}: IconButtonProps) {
  const iconSize = size === 'sm' ? 18 : size === 'lg' ? 24 : 20;
  const inner = (
    <>
      {loading ? <Spinner size={iconSize} /> : <Icon name={icon} size={iconSize} filled={filled} />}
      {badge ? (
        <span
          aria-hidden
          className={cn(
            'absolute grid place-items-center rounded-full bg-danger font-extrabold text-white ring-2 ring-surface tnum',
            typeof badge === 'number' ? '-top-1 -right-1 h-[18px] min-w-[18px] px-1 text-[10px]' : 'top-1.5 right-1.5 size-2.5',
          )}
        >
          {typeof badge === 'number' ? (badge > 99 ? '99+' : badge) : null}
        </span>
      ) : null}
    </>
  );
  const accessibleName = typeof badge === 'number' && badge > 0 ? `${label} (${badge})` : label;
  const cls = cn(iconButtonVariants({ variant, size, shape }), className);
  if (href !== undefined) {
    const Comp = linkAs ?? 'a';
    return (
      <Comp href={href} aria-label={accessibleName} title={label} className={cls}>
        {inner}
      </Comp>
    );
  }
  return (
    <button
      {...rest}
      ref={ref}
      type={type}
      aria-label={accessibleName}
      title={rest.title ?? label}
      aria-busy={loading || undefined}
      className={cls}
    >
      {inner}
    </button>
  );
}
