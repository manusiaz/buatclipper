// @clipper/ui — Clipper design system (tokens in ./styles.css, components below).
// Components with state/effects carry 'use client' in their own module; everything else is server-compatible.

export { cn } from './lib/cn';
export {
  formatNumber,
  formatCompact,
  formatIDR,
  formatRelative,
  formatDateTime,
  formatDate,
  durationParts,
  earningFor,
  initials,
  type UiLocale,
} from './lib/format';

// Brand & icons
export { Icon, iconNames, type IconName, type IconProps } from './components/icon';
export { PlatformIcon, PlatformChip, PLATFORMS, platformLabels, platformLabel, type Platform, type PlatformIconProps, type PlatformChipProps } from './components/platform-icon';
export { Logo, LogoMark, type LogoProps, type LogoMarkProps, type LogoVariant } from './components/logo';

// Actions
export { Button, IconButton, buttonVariants, iconButtonVariants, type ButtonProps, type ButtonVariant, type ButtonSize, type IconButtonProps } from './components/button';
export { Spinner, type SpinnerProps } from './components/spinner';

// Forms
export { Input, Textarea, type InputProps, type TextareaProps } from './components/input';
export { SearchInput, type SearchInputProps } from './components/search-input';
export { Select, type SelectProps, type SelectOption, type SelectGroup } from './components/select';
export { Checkbox, type CheckboxProps } from './components/checkbox';
export { RadioGroup, type RadioGroupProps, type RadioOption } from './components/radio-group';
export { Switch, type SwitchProps } from './components/switch';
export { Field, Fieldset, type FieldProps, type FieldControlProps, type FieldsetProps } from './components/field';
export { CopyField, type CopyFieldProps } from './components/copy-field';

// Surfaces & data display
export { Card, CardHeader, CardTitle, CardDescription, CardContent, CardFooter, cardVariants, type CardProps, type CardVariant } from './components/card';
export { CampaignCard, type CampaignCardProps, type CampaignCtaState, type CampaignRate, type CampaignCardLabels } from './components/campaign-card';
export { StatCard, type StatCardProps, type StatDelta } from './components/stat-card';
export {
  Badge,
  StatusBadge,
  statusTone,
  badgeVariants,
  STATUS_KINDS,
  type BadgeProps,
  type BadgeTone,
  type StatusBadgeProps,
  type StatusKind,
  type StatusOf,
} from './components/badge';
export { Table, THead, TBody, TFoot, TR, TH, TD, type TableProps, type THProps, type TDProps, type TRProps, type SortDirection } from './components/table';
export { ProgressBar, type ProgressBarProps } from './components/progress-bar';
export { Avatar, AvatarGroup, type AvatarProps, type AvatarGroupProps } from './components/avatar';
export { Money, type MoneyProps } from './components/money';
export { RelativeTime, type RelativeTimeProps } from './components/relative-time';
export { Countdown, type CountdownProps } from './components/countdown';
export { Stepper, type StepperProps, type StepperStep } from './components/stepper';
export { EmbedFrame, toEmbedUrl, type EmbedFrameProps, type EmbedInfo } from './components/embed-frame';

// Navigation
export { Tabs, TabsList, TabsTrigger, TabsContent, type TabsProps, type TabsListProps, type TabsTriggerProps } from './components/tabs';
export { Pagination, type PaginationProps } from './components/pagination';
export { Breadcrumb, type BreadcrumbProps, type BreadcrumbItem } from './components/breadcrumb';

// Overlays & feedback
export { Dialog, DialogTrigger, DialogClose, DialogPortal, DialogOverlay, DialogContent, type DialogContentProps } from './components/dialog';
export { Dialog as Modal, DialogContent as ModalContent } from './components/dialog';
export { Sheet, SheetTrigger, SheetClose, SheetContent, type SheetContentProps } from './components/sheet';
export { ConfirmDialog, type ConfirmDialogProps } from './components/confirm-dialog';
export { Toaster, toast, type ToasterProps } from './components/toaster';
export { Tooltip, TooltipProvider, type TooltipProps } from './components/tooltip';
export { Popover, PopoverTrigger, PopoverContent, PopoverClose, PopoverAnchor } from './components/popover';
export {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLinkItem,
  DropdownMenuCheckboxItem,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuGroup,
  type DropdownMenuItemProps,
  type DropdownMenuLinkItemProps,
} from './components/dropdown-menu';
export { Alert, Alert as Banner, type AlertProps, type AlertTone } from './components/alert';
export { Skeleton, CampaignCardSkeleton, type SkeletonProps } from './components/skeleton';
export { EmptyState, ErrorState, type EmptyStateProps, type ErrorStateProps, type StateAction } from './components/empty-state';

// Layout
export { Container, Section, PageHeader, type ContainerProps, type SectionProps, type PageHeaderProps } from './components/layout';
export { ThemeProvider, ThemeToggle, useTheme, type ThemeProviderProps, type ThemeToggleProps } from './components/theme';

// Shells
export { MobileAppShell, type MobileAppShellProps } from './shells/mobile-app-shell';
export { SidebarShell, type SidebarShellProps } from './shells/sidebar-shell';
export { PublicShell, type PublicShellProps } from './shells/public-shell';
export { AuthShell, type AuthShellProps } from './shells/auth-shell';
export { NavDrawer, type NavDrawerProps } from './shells/nav-drawer';
export type { NavItem, NavSection, FooterColumn } from './shells/types';
