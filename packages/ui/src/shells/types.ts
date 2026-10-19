import type { IconName } from '../components/icon';

/** Navigation item passed by apps (no routing logic inside ui; the app decides `active`). */
export interface NavItem {
  href: string;
  label: string;
  icon?: IconName;
  /** Current route (sets aria-current="page" and the active style). */
  active?: boolean;
  /** Count (number), dot (true) or short text ("Baru"). */
  badge?: number | boolean | string;
  /** Opens in a new tab. */
  external?: boolean;
}

export interface NavSection {
  title?: string;
  items: NavItem[];
}

export interface FooterColumn {
  title: string;
  links: Array<{ label: string; href: string; external?: boolean }>;
}
