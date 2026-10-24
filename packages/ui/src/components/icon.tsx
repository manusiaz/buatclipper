import type { SVGProps } from 'react';
import { ICON_VIEWBOX, iconAliases, iconPaths, type IconName } from '../icons.generated';
import { cn } from '../lib/cn';

export type { IconName };

export interface IconProps extends Omit<SVGProps<SVGSVGElement>, 'name' | 'children'> {
  /** Material Symbols Rounded name (curated set, see icons.generated.ts). */
  name: IconName;
  /** Pixel size (width = height). Default 20. Use 16/18/20/24 per DS 19. */
  size?: number;
  /** Filled variant (active nav, status icons). Falls back to outline when no fill glyph exists. */
  filled?: boolean;
  /** Accessible name. Without it the icon is decorative (aria-hidden). */
  title?: string;
}

function resolve(name: IconName): readonly string[] {
  const key = (name in iconAliases ? iconAliases[name as keyof typeof iconAliases] : name) as keyof typeof iconPaths;
  return iconPaths[key];
}

/** Inline SVG icon (Material Symbols Rounded, weight 400). Inherits `currentColor`. Server-compatible. */
export function Icon({ name, size = 20, filled = false, title, className, ...rest }: IconProps) {
  const paths = resolve(name);
  const d = filled ? (paths[1] ?? paths[0]) : paths[0];
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox={ICON_VIEWBOX}
      width={size}
      height={size}
      fill="currentColor"
      aria-hidden={title ? undefined : true}
      role={title ? 'img' : undefined}
      aria-label={title}
      focusable="false"
      className={cn('inline-block shrink-0', className)}
      {...rest}
    >
      {title ? <title>{title}</title> : null}
      <path d={d} />
    </svg>
  );
}

export const iconNames = [...Object.keys(iconPaths), ...Object.keys(iconAliases)] as IconName[];
