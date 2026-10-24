// Hubungkan akun sosmed dari app: OAuth resmi platform di browser in-app (sesi dibawa lewat handoff) → callback web
// → /app-return → clipper://social?connected=…|error=… (auth session tertutup) → hasil dibaca di sini.
import type { Platform } from '@clipper/ui/platform-paths';
import { openWeb } from './web';

export type ConnectResult = { connected?: string; handle?: string; error?: string; platform?: string; pages?: string } | null;

export function parseReturn(url: string | null): ConnectResult {
  if (!url) return null;
  try {
    const q = new URL(url.replace(/^clipper:\/\//, 'https://app.invalid/')).searchParams;
    const pick = (k: string) => q.get(k)?.slice(0, 2048) || undefined;
    return { connected: pick('connected'), handle: pick('handle'), error: pick('error'), platform: pick('platform'), pages: pick('pages') };
  } catch {
    return null;
  }
}

export async function connectPlatform(platform: Platform, pageId?: string): Promise<ConnectResult> {
  const q = new URLSearchParams({ next: '/app-return', ...(pageId ? { page_id: pageId } : {}) });
  return parseReturn(await openWeb('app', `/api/oauth/${platform}/start?${q}`, { back: true }));
}
