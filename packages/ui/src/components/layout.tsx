import type { ElementType, HTMLAttributes, ReactNode } from 'react';
import { cn } from '../lib/cn';

export interface ContainerProps extends HTMLAttributes<HTMLElement> {
  /** sm 680 (article) · md 960 · lg 1200 (DS desktop container, default) · full. */
  size?: 'sm' | 'md' | 'lg' | 'full';
  as?: ElementType;
}

const MAX = { sm: 'max-w-[calc(680px_+_2*var(--gutter))]', md: 'max-w-[calc(960px_+_2*var(--gutter))]', lg: 'max-w-[calc(1200px_+_2*var(--gutter))]', full: 'max-w-none' };

/** Centered container with DS margins: 20 px mobile · 40 px tablet/desktop; content max 1200 px. */
export function Container({ size = 'lg', as: Comp = 'div', className, ...rest }: ContainerProps) {
  return <Comp className={cn('mx-auto w-full px-(--gutter) [--gutter:20px] md:[--gutter:40px]', MAX[size], className)} {...rest} />;
}

export interface SectionProps extends Omit<HTMLAttributes<HTMLElement>, 'title'> {
  /** Section heading (DS 13 title pattern A). */
  title?: ReactNode;
  /** Overline/eyebrow above the title (12/600 +18 % uppercase). */
  eyebrow?: ReactNode;
  description?: ReactNode;
  /** Right-aligned link/actions ("Lihat semua →"). */
  actions?: ReactNode;
  /** Heading level for `title`. Default h2. */
  as?: 'h1' | 'h2' | 'h3';
  /** Background band: canvas (none) · surface · tint · dark · blue (DS 13 §9). */
  tone?: 'none' | 'surface' | 'tint' | 'dark' | 'blue';
  /** Vertical rhythm: page sections 48 → 96 px (DS 05 §7) or `compact` 24 → 32 px for app screens. */
  spacing?: 'page' | 'compact' | 'none';
  /** Wrap children in <Container>. Default true for toned page sections, false otherwise. */
  contained?: boolean;
}

/** Page section with a consistent title pattern and spacing. Server-compatible. */
export function Section({
  title,
  eyebrow,
  description,
  actions,
  as: H = 'h2',
  tone = 'none',
  spacing = 'compact',
  contained,
  className,
  children,
  ...rest
}: SectionProps) {
  const onDark = tone === 'dark' || tone === 'blue';
  const wrap = contained ?? (tone !== 'none' && spacing === 'page');
  const head =
    title || eyebrow || actions ? (
      <div className={cn('flex flex-wrap items-end justify-between gap-x-6 gap-y-3', spacing === 'page' ? 'mb-8' : 'mb-4')}>
        <div className="flex max-w-[56ch] min-w-0 flex-col gap-2">
          {eyebrow ? <p className={cn('text-overline uppercase', onDark ? 'text-brand-300' : 'text-primary-soft-fg')}>{eyebrow}</p> : null}
          {title ? <H className={cn(spacing === 'page' ? 'text-h2' : 'text-h5', onDark && 'text-white')}>{title}</H> : null}
          {description ? <p className={cn(spacing === 'page' ? 'text-body-l' : 'text-body-s', onDark ? 'text-white/75' : 'text-muted')}>{description}</p> : null}
        </div>
        {actions ? <div className="flex shrink-0 items-center gap-2">{actions}</div> : null}
      </div>
    ) : null;
  const body = (
    <>
      {head}
      {children}
    </>
  );
  return (
    <section
      className={cn(
        spacing === 'page' && 'py-12 md:py-20 xl:py-24',
        spacing === 'compact' && 'py-6 md:py-8',
        tone === 'surface' && 'bg-surface',
        tone === 'tint' && 'bg-primary-soft',
        tone === 'dark' && 'surface-dark shadow-none',
        tone === 'blue' && 'surface-blue shadow-none',
        className,
      )}
      {...rest}
    >
      {wrap ? <Container>{body}</Container> : body}
    </section>
  );
}

export interface PageHeaderProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  title: ReactNode;
  description?: ReactNode;
  /** <Breadcrumb/> element. */
  breadcrumb?: ReactNode;
  /** Primary/secondary actions (one primary max). Stack under the title on mobile. */
  actions?: ReactNode;
  /** Badges next to the title (status). */
  meta?: ReactNode;
  /** Back link for app sub-pages (mobile). */
  back?: ReactNode;
}

/** Page title block for app/admin screens (h1 + description + actions + breadcrumb). Server-compatible. */
export function PageHeader({ title, description, breadcrumb, actions, meta, back, className, ...rest }: PageHeaderProps) {
  return (
    <div className={cn('flex flex-col gap-3 pt-2 pb-5 md:pb-6', className)} {...rest}>
      {breadcrumb}
      {back}
      <div className="flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
        <div className="flex min-w-0 flex-col gap-1.5">
          <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
            <h1 className="text-h3 text-ink">{title}</h1>
            {meta}
          </div>
          {description ? <p className="max-w-[64ch] text-body text-muted">{description}</p> : null}
        </div>
        {actions ? <div className="flex flex-wrap items-center gap-2 max-md:[&>*]:flex-1">{actions}</div> : null}
      </div>
    </div>
  );
}
