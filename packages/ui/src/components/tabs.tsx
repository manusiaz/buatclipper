'use client';

import * as TabsPrimitive from '@radix-ui/react-tabs';
import type { ComponentProps, ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Icon, type IconName } from './icon';

export interface TabsProps extends ComponentProps<typeof TabsPrimitive.Root> {}

/** Tabs root (Radix). Use `value`/`onValueChange` to sync with the URL in apps. */
export function Tabs({ className, ...rest }: TabsProps) {
  return <TabsPrimitive.Root className={cn('flex flex-col gap-4', className)} {...rest} />;
}

export interface TabsListProps extends ComponentProps<typeof TabsPrimitive.List> {
  /** `underline` (page sections, default) or `pill` (segmented filter). */
  variant?: 'underline' | 'pill';
  /** Stretch triggers to equal width (mobile segmented control). */
  fullWidth?: boolean;
}

/** Scrolls horizontally on small screens (DS 15: "Tabs bisa digeser"). */
export function TabsList({ className, variant = 'underline', fullWidth, ...rest }: TabsListProps) {
  return (
    <TabsPrimitive.List
      data-variant={variant}
      className={cn(
        'group/tabs no-scrollbar flex max-w-full overflow-x-auto',
        variant === 'underline' ? 'gap-1 border-b border-border' : 'w-fit gap-1 rounded-control bg-subtle p-1',
        fullWidth && 'w-full [&>*]:flex-1',
        className,
      )}
      {...rest}
    />
  );
}

export interface TabsTriggerProps extends ComponentProps<typeof TabsPrimitive.Trigger> {
  icon?: IconName;
  /** Count shown next to the label. */
  count?: ReactNode;
}

export function TabsTrigger({ className, icon, count, children, ...rest }: TabsTriggerProps) {
  return (
    <TabsPrimitive.Trigger
      className={cn(
        'relative inline-flex shrink-0 items-center justify-center gap-1.5 text-sm font-semibold whitespace-nowrap text-muted',
        'transition-[color,background-color,box-shadow] duration-120 ease-out focus-ring disabled:pointer-events-none disabled:text-disabled-fg',
        // underline
        'group-data-[variant=underline]/tabs:h-11 group-data-[variant=underline]/tabs:rounded-t-[10px] group-data-[variant=underline]/tabs:px-3.5',
        'group-data-[variant=underline]/tabs:hover:text-ink group-data-[variant=underline]/tabs:data-[state=active]:font-bold group-data-[variant=underline]/tabs:data-[state=active]:text-ink',
        "group-data-[variant=underline]/tabs:after:absolute group-data-[variant=underline]/tabs:after:inset-x-2 group-data-[variant=underline]/tabs:after:-bottom-px group-data-[variant=underline]/tabs:after:h-[3px] group-data-[variant=underline]/tabs:after:rounded-full group-data-[variant=underline]/tabs:after:content-['']",
        'group-data-[variant=underline]/tabs:data-[state=active]:after:bg-primary',
        // pill
        'group-data-[variant=pill]/tabs:h-9 group-data-[variant=pill]/tabs:rounded-[9px] group-data-[variant=pill]/tabs:px-3.5',
        'group-data-[variant=pill]/tabs:hover:text-ink group-data-[variant=pill]/tabs:data-[state=active]:bg-surface group-data-[variant=pill]/tabs:data-[state=active]:font-bold',
        'group-data-[variant=pill]/tabs:data-[state=active]:text-ink group-data-[variant=pill]/tabs:data-[state=active]:shadow-hairline',
        className,
      )}
      {...rest}
    >
      {icon ? <Icon name={icon} size={18} /> : null}
      {children}
      {count != null ? (
        <span className="grid h-5 min-w-5 place-items-center rounded-full bg-subtle px-1.5 text-[11px] font-bold text-text-2 tnum group-data-[variant=pill]/tabs:bg-border">
          {count}
        </span>
      ) : null}
    </TabsPrimitive.Trigger>
  );
}

export function TabsContent({ className, ...rest }: ComponentProps<typeof TabsPrimitive.Content>) {
  return <TabsPrimitive.Content className={cn('outline-none focus-visible:ring-0', className)} {...rest} />;
}
