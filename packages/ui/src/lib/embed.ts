// Link postingan publik → URL embed resmi platform (pure; dipakai EmbedFrame web dan app native).
import type { Platform } from './platform-paths';

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
