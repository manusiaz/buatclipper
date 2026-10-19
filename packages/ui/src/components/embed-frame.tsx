import type { ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Icon } from './icon';
import { PlatformIcon, platformLabels, type Platform } from './platform-icon';

export interface EmbedInfo {
  platform: Platform;
  /** Official iframe embed URL (origins allowed by the CSP frame-src in @clipper/auth). */
  src: string;
  /** CSS aspect-ratio. */
  aspect: '9 / 16' | '16 / 9' | '4 / 5' | '1 / 1';
  id: string;
}

const host = (u: URL) => u.hostname.replace(/^(www\.|m\.|mobile\.)/, '');

/**
 * Public post URL → official embed iframe URL, or null when the URL is not a recognised public post
 * (short links like vm.tiktok.com / fb.watch need server-side resolution first). Pure; safe anywhere.
 */
export function toEmbedUrl(raw: string): EmbedInfo | null {
  let u: URL;
  try {
    u = new URL(raw.trim());
  } catch {
    return null;
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
  const h = host(u);
  const path = u.pathname;
  let m: RegExpMatchArray | null;

  if (h === 'tiktok.com') {
    m = path.match(/\/(?:@[\w.-]+\/video|embed\/v2|player\/v1|video)\/(\d{8,})/);
    if (m?.[1]) return { platform: 'tiktok', id: m[1], src: `https://www.tiktok.com/player/v1/${m[1]}?description=1&rel=0`, aspect: '9 / 16' };
    return null;
  }
  if (h === 'instagram.com') {
    m = path.match(/^\/(?:[\w.]+\/)?(p|reel|reels|tv)\/([\w-]+)/);
    if (m?.[1] && m[2]) {
      const kind = m[1] === 'p' ? 'p' : 'reel';
      return { platform: 'instagram', id: m[2], src: `https://www.instagram.com/${kind}/${m[2]}/embed`, aspect: kind === 'p' ? '4 / 5' : '9 / 16' };
    }
    return null;
  }
  if (h === 'youtube.com' || h === 'youtu.be' || h === 'youtube-nocookie.com') {
    let id: string | null = null;
    let short = false;
    if (h === 'youtu.be') id = path.slice(1).split('/')[0] ?? null;
    else if ((m = path.match(/^\/(shorts|embed|live|v)\/([\w-]{6,})/))) {
      id = m[2] ?? null;
      short = m[1] === 'shorts';
    } else if (path === '/watch') id = u.searchParams.get('v');
    if (id && /^[\w-]{6,}$/.test(id)) {
      return { platform: 'youtube', id, src: `https://www.youtube-nocookie.com/embed/${id}?rel=0&modestbranding=1`, aspect: short ? '9 / 16' : '16 / 9' };
    }
    return null;
  }
  if (h === 'threads.net' || h === 'threads.com') {
    m = path.match(/^\/(@[\w.]+)\/post\/([\w-]+)/);
    if (m?.[1] && m[2]) return { platform: 'threads', id: m[2], src: `https://www.threads.net/${m[1]}/post/${m[2]}/embed`, aspect: '4 / 5' };
    return null;
  }
  if (h === 'facebook.com') {
    const isVideo = /\/(videos|reel|watch)\b/.test(path) || u.searchParams.has('v');
    const isReel = /\/reel\//.test(path);
    const idMatch = path.match(/\/(?:videos|reel|posts)\/([\w.-]+)/) ?? null;
    const id = idMatch?.[1] ?? u.searchParams.get('v') ?? u.searchParams.get('story_fbid');
    if (!id) return null;
    const canonical = `https://www.facebook.com${path}${u.search}`;
    const plugin = isVideo ? 'video' : 'post';
    return {
      platform: 'facebook',
      id,
      src: `https://www.facebook.com/plugins/${plugin}.php?href=${encodeURIComponent(canonical)}&show_text=false`,
      aspect: isReel ? '9 / 16' : isVideo ? '16 / 9' : '4 / 5',
    };
  }
  if (h === 'x.com' || h === 'twitter.com') {
    m = path.match(/^\/\w+\/status(?:es)?\/(\d+)/);
    if (m?.[1]) return { platform: 'x', id: m[1], src: `https://platform.twitter.com/embed/Tweet.html?id=${m[1]}&dnt=true`, aspect: '4 / 5' };
    return null;
  }
  return null;
}

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
