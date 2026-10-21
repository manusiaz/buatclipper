import type { ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Icon } from './icon';
import { toEmbedUrl } from '../lib/embed';
import { PlatformIcon, platformLabels } from './platform-icon';

export { toEmbedUrl, type EmbedInfo } from '../lib/embed';

export interface EmbedFrameProps {
  /** Public post URL as submitted by the clipper. */
  url: string;
  /** Accessible iframe title, e.g. "Klip @raka.clips di TikTok". */
  title: string;
  /** Max width of the frame (default 340 px for vertical, 100 % for 16:9). */
  maxWidth?: number | string;
  /** Rendered when the URL can't be embedded. Default: link card "Buka di <platform>". */
  fallback?: ReactNode;
  /** Label for the fallback link. */
  openLabel?: string;
  className?: string;
}

/**
 * Lazy, sandboxed official embed for TikTok / Instagram / YouTube / Threads / Facebook / X (review & submission
 * screens). No third-party script is loaded by us — only the platform iframe. Server-compatible.
 */
export function EmbedFrame({ url, title, maxWidth, fallback, openLabel, className }: EmbedFrameProps) {
  const info = toEmbedUrl(url);
  if (!info) {
    if (fallback !== undefined) return <>{fallback}</>;
    let label = 'link';
    try {
      label = new URL(url).hostname.replace(/^www\./, '');
    } catch {
      /* invalid URL */
    }
    return (
      <a
        href={url}
        target="_blank"
        rel="noopener noreferrer nofollow"
        className={cn(
          'flex items-center gap-3 rounded-card-sm border border-border bg-surface-2 p-3 text-sm font-semibold text-ink hover:border-border-hover focus-ring',
          className,
        )}
      >
        <Icon name="link" size={20} className="text-muted" />
        <span className="min-w-0 flex-1 truncate">{openLabel ?? `Buka di ${label}`}</span>
        <Icon name="open_in_new" size={18} className="text-muted" />
      </a>
    );
  }
  const vertical = info.aspect === '9 / 16' || info.aspect === '4 / 5';
  return (
    <figure className={cn('flex w-full flex-col gap-2', className)} style={{ maxWidth: maxWidth ?? (vertical ? 340 : undefined) }}>
      <div className="skeleton-shimmer animate-shimmer relative w-full overflow-hidden rounded-card-sm bg-navy shadow-card" style={{ aspectRatio: info.aspect }}>
        <iframe
          src={info.src}
          title={title}
          loading="lazy"
          sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox allow-presentation"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
          referrerPolicy="strict-origin-when-cross-origin"
          allowFullScreen
          className="absolute inset-0 size-full border-0"
        />
      </div>
      <figcaption className="flex items-center justify-between gap-2 text-caption text-muted">
        <span className="inline-flex items-center gap-1.5 font-semibold">
          <PlatformIcon platform={info.platform} size={14} />
          {platformLabels[info.platform]}
        </span>
        <a href={url} target="_blank" rel="noopener noreferrer nofollow" className="inline-flex items-center gap-1 rounded-tag font-semibold text-link hover:underline focus-ring">
          {openLabel ?? 'Buka asli'}
          <Icon name="open_in_new" size={14} />
        </a>
      </figcaption>
    </figure>
  );
}
