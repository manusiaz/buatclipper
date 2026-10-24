import type { ElementType, HTMLAttributes, ReactNode, TdHTMLAttributes, ThHTMLAttributes } from 'react';
import { cn } from '../lib/cn';
import { Icon } from './icon';

export interface TableProps extends HTMLAttributes<HTMLTableElement> {
  /** Wrap in a card that scrolls horizontally (DS 15: tables scroll inside their card on mobile). Default true. */
  card?: boolean;
  /** Sticky header inside the scroll container (set `maxHeight` to scroll vertically). */
  stickyHeader?: boolean;
  /** Max height of the scroll container (e.g. "60vh") to enable vertical scroll + sticky header. */
  maxHeight?: string;
  /** Compact rows (admin). */
  dense?: boolean;
  /** Caption for screen readers (visually hidden unless `captionVisible`). */
  caption?: ReactNode;
  captionVisible?: boolean;
  /** Toolbar above the table (inside the card): title, filters, export. */
  toolbar?: ReactNode;
  /** Footer below the table (inside the card): totals, bulk actions, pagination. */
  footer?: ReactNode;
  containerClassName?: string;
}

/** Data table (DS 11 §1). Server-compatible; sorting is handled by the caller via <TH sort onSort|sortHref>. */
export function Table({
  card = true,
  stickyHeader = true,
  maxHeight,
  dense,
  caption,
  captionVisible,
  toolbar,
  footer,
  className,
  containerClassName,
  children,
  ...rest
}: TableProps) {
  const table = (
    <div
      className={cn('relative w-full overflow-auto overscroll-x-contain', !card && containerClassName)}
      style={maxHeight ? { maxHeight } : undefined}
      tabIndex={0}
      role="region"
      aria-label={typeof caption === 'string' ? caption : 'Tabel'}
    >
      <table
        data-dense={dense || undefined}
        data-sticky={stickyHeader || undefined}
        className={cn('group/table w-full min-w-max border-separate border-spacing-0 text-left text-sm', className)}
        {...rest}
      >
        {caption ? <caption className={captionVisible ? 'p-4 text-left text-h6' : 'sr-only'}>{caption}</caption> : null}
        {children}
      </table>
    </div>
  );
  if (!card) return table;
  return (
    <div className={cn('surface-card overflow-hidden rounded-card', containerClassName)}>
      {toolbar ? <div className="flex flex-wrap items-center justify-between gap-3 border-b border-border px-4 py-3">{toolbar}</div> : null}
      {table}
      {footer ? <div className="flex flex-wrap items-center justify-between gap-3 border-t border-border px-4 py-3">{footer}</div> : null}
    </div>
  );
}

export function THead({ className, ...rest }: HTMLAttributes<HTMLTableSectionElement>) {
  return <thead className={cn('group-data-[sticky]/table:sticky group-data-[sticky]/table:top-0 group-data-[sticky]/table:z-10', className)} {...rest} />;
}

export function TBody({ className, ...rest }: HTMLAttributes<HTMLTableSectionElement>) {
  return <tbody className={cn('[&>tr:last-child>td]:border-b-0', className)} {...rest} />;
}

export function TFoot({ className, ...rest }: HTMLAttributes<HTMLTableSectionElement>) {
  return <tfoot className={cn('bg-surface-2 font-bold [&_td]:border-t [&_td]:border-b-0 [&_td]:border-border', className)} {...rest} />;
}

export interface TRProps extends HTMLAttributes<HTMLTableRowElement> {
  /** Selected row (DS: bg blue-50). */
  selected?: boolean;
  /** Hover highlight + pointer (row opens detail). */
  interactive?: boolean;
}

export function TR({ selected, interactive, className, ...rest }: TRProps) {
  return (
    <tr
      aria-selected={selected || undefined}
      className={cn(
        'transition-colors duration-120 [&>td]:bg-surface',
        interactive && 'cursor-pointer hover:[&>td]:bg-surface-2',
        selected && '[&>td]:bg-primary-tint hover:[&>td]:bg-primary-tint',
        className,
      )}
      {...rest}
    />
  );
}

export type SortDirection = 'asc' | 'desc' | false;

export interface THProps extends ThHTMLAttributes<HTMLTableCellElement> {
  /** Current sort of this column. `false` = sortable but not active; undefined = not sortable. */
  sort?: SortDirection;
  /** Client-side sort toggle. */
  onSort?: () => void;
  /** Server-side sort link (use in server components). */
  sortHref?: string;
  linkAs?: ElementType;
  align?: 'left' | 'right' | 'center';
  /** Pin the first column while scrolling horizontally. */
  sticky?: boolean;
}

/** Header cell (10–12/700, subtle bg). Sortable columns render a button/link with arrow + aria-sort. */
export function TH({ sort, onSort, sortHref, linkAs, align = 'left', sticky, className, children, ...rest }: THProps) {
  const sortable = sort !== undefined;
  const ariaSort = sort === 'asc' ? 'ascending' : sort === 'desc' ? 'descending' : sortable ? 'none' : undefined;
  const indicator = sortable ? (
    <Icon
      name={sort === 'asc' ? 'arrow_upward' : sort === 'desc' ? 'arrow_downward' : 'unfold_more'}
      size={14}
      className={cn(sort ? 'text-primary-soft-fg' : 'opacity-50')}
    />
  ) : null;
  const inner = sortable ? (
    sortHref ? (
      (() => {
        const L = linkAs ?? 'a';
        return (
          <L href={sortHref} className={cn('inline-flex items-center gap-1 rounded-tag hover:text-ink focus-ring', sort && 'text-primary-soft-fg')}>
            {children}
            {indicator}
          </L>
        );
      })()
    ) : (
      <button type="button" onClick={onSort} className={cn('inline-flex items-center gap-1 rounded-tag uppercase hover:text-ink focus-ring', sort && 'text-primary-soft-fg')}>
        {children}
        {indicator}
      </button>
    )
  ) : (
    children
  );
  return (
    <th
      scope="col"
      aria-sort={ariaSort}
      className={cn(
        'h-10 border-b border-border bg-surface-2 px-4 text-[11px] font-bold tracking-[0.06em] whitespace-nowrap text-muted uppercase',
        'group-data-[dense]/table:h-9 group-data-[dense]/table:px-3',
        align === 'right' && 'text-right [&>*]:flex-row-reverse',
        align === 'center' && 'text-center',
        sticky && 'sticky left-0 z-[1]',
        className,
      )}
      {...rest}
    >
      {inner}
    </th>
  );
}

export interface TDProps extends TdHTMLAttributes<HTMLTableCellElement> {
  align?: 'left' | 'right' | 'center';
  /** Numbers: right-aligned + tabular figures (DS 11: "Angka rata kanan"). */
  numeric?: boolean;
  sticky?: boolean;
  /** Muted secondary text style. */
  muted?: boolean;
}

export function TD({ align, numeric, sticky, muted, className, ...rest }: TDProps) {
  const a = align ?? (numeric ? 'right' : 'left');
  return (
    <td
      className={cn(
        'h-14 border-b border-border px-4 align-middle text-ink group-data-[dense]/table:h-11 group-data-[dense]/table:px-3',
        a === 'right' && 'text-right',
        a === 'center' && 'text-center',
        numeric && 'font-semibold whitespace-nowrap tnum',
        muted && 'text-muted',
        sticky && 'sticky left-0 z-[1]',
        className,
      )}
      {...rest}
    />
  );
}
