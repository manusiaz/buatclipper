'use client';

import * as Menu from '@radix-ui/react-dropdown-menu';
import type { ComponentProps, ElementType, ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Icon, type IconName } from './icon';

export const DropdownMenu = Menu.Root;
export const DropdownMenuTrigger = Menu.Trigger;
export const DropdownMenuGroup = Menu.Group;
export const DropdownMenuRadioGroup = Menu.RadioGroup;

export function DropdownMenuContent({ className, sideOffset = 8, align = 'end', ...rest }: ComponentProps<typeof Menu.Content>) {
  return (
    <Menu.Portal>
      <Menu.Content
        sideOffset={sideOffset}
        align={align}
        collisionPadding={12}
        className={cn(
          'z-50 min-w-[220px] max-w-[calc(100vw-24px)] rounded-popover border border-border bg-surface p-1.5 text-ink shadow-pop outline-none',
          'data-[state=open]:animate-pop-in data-[state=closed]:animate-pop-out',
          className,
        )}
        {...rest}
      />
    </Menu.Portal>
  );
}

const itemCls = cn(
  'relative flex min-h-11 cursor-pointer select-none items-center gap-3 rounded-[10px] px-3 py-2 text-sm font-semibold text-ink outline-none md:min-h-10',
  'data-[highlighted]:bg-subtle data-[disabled]:cursor-not-allowed data-[disabled]:text-disabled-fg',
);

export interface DropdownMenuItemProps extends ComponentProps<typeof Menu.Item> {
  icon?: IconName;
  /** Right side: shortcut, count, value ("Rp482rb"). */
  aside?: ReactNode;
  /** Destructive item (red, e.g. "Keluar", "Hapus"). */
  tone?: 'default' | 'danger';
  description?: ReactNode;
}

export function DropdownMenuItem({ icon, aside, tone = 'default', description, className, children, ...rest }: DropdownMenuItemProps) {
  return (
    <Menu.Item className={cn(itemCls, tone === 'danger' && 'text-danger-fg data-[highlighted]:bg-danger-bg', className)} {...rest}>
      {icon ? <Icon name={icon} size={20} className={tone === 'danger' ? 'text-danger-fg' : 'text-muted'} /> : null}
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="truncate">{children}</span>
        {description ? <span className="text-caption font-normal text-muted">{description}</span> : null}
      </span>
      {aside != null ? <span className="text-caption font-semibold text-muted tnum">{aside}</span> : null}
    </Menu.Item>
  );
}

export interface DropdownMenuLinkItemProps extends Omit<DropdownMenuItemProps, 'asChild'> {
  href: string;
  linkAs?: ElementType;
  external?: boolean;
}

/** Menu item that navigates (renders a link, keeps menu keyboard semantics). */
export function DropdownMenuLinkItem({ href, linkAs, external, icon, aside, tone = 'default', description, className, children, ...rest }: DropdownMenuLinkItemProps) {
  const L = linkAs ?? 'a';
  return (
    <Menu.Item asChild {...rest}>
      <L
        href={href}
        target={external ? '_blank' : undefined}
        rel={external ? 'noopener noreferrer' : undefined}
        className={cn(itemCls, tone === 'danger' && 'text-danger-fg data-[highlighted]:bg-danger-bg', className)}
      >
        {icon ? <Icon name={icon} size={20} className={tone === 'danger' ? 'text-danger-fg' : 'text-muted'} /> : null}
        <span className="flex min-w-0 flex-1 flex-col">
          <span className="truncate">{children}</span>
          {description ? <span className="text-caption font-normal text-muted">{description}</span> : null}
        </span>
        {aside != null ? <span className="text-caption font-semibold text-muted tnum">{aside}</span> : null}
        {external ? <Icon name="open_in_new" size={16} className="text-muted" /> : null}
      </L>
    </Menu.Item>
  );
}

export function DropdownMenuCheckboxItem({ className, children, ...rest }: ComponentProps<typeof Menu.CheckboxItem>) {
  return (
    <Menu.CheckboxItem className={cn(itemCls, 'pr-9', className)} {...rest}>
      {children}
      <Menu.ItemIndicator className="absolute right-3 inline-flex text-primary">
        <Icon name="check" size={18} />
      </Menu.ItemIndicator>
    </Menu.CheckboxItem>
  );
}

export function DropdownMenuRadioItem({ className, children, ...rest }: ComponentProps<typeof Menu.RadioItem>) {
  return (
    <Menu.RadioItem className={cn(itemCls, 'pr-9 data-[state=checked]:font-bold', className)} {...rest}>
      {children}
      <Menu.ItemIndicator className="absolute right-3 inline-flex text-primary">
        <Icon name="check" size={18} />
      </Menu.ItemIndicator>
    </Menu.RadioItem>
  );
}

export function DropdownMenuLabel({ className, ...rest }: ComponentProps<typeof Menu.Label>) {
  return <Menu.Label className={cn('px-3 pt-2 pb-1 text-[11px] font-bold tracking-[0.14em] text-muted uppercase', className)} {...rest} />;
}

export function DropdownMenuSeparator({ className, ...rest }: ComponentProps<typeof Menu.Separator>) {
  return <Menu.Separator className={cn('my-1.5 h-px bg-border', className)} {...rest} />;
}
