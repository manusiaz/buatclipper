// Data header app (lonceng, avatar, menu komunitas/AI Clip). Dibaca root layout; null = tanpa shell (login, belum onboarding).
import { getAuth } from '@clipper/auth/server';
import { isAdmin } from '@clipper/auth';
import { communityLinks, httpsUrl } from '@clipper/clipper-lib/pure';
import { core, publicUrl } from '../lib/server';

export interface ChromeData {
  unread: number;
  name: string;
  username: string | null;
  avatar: string | null;
  socialAttention: boolean;
  community: { key: string; href: string }[];
  aiClip: string | null;
}

export async function loadChrome(): Promise<ChromeData | null> {
  const { claims } = await getAuth('sso');
  if (!claims || isAdmin(claims) || !claims.consent_ok?.clipper) return null;
  const fallback: ChromeData = {
    unread: 0,
    name: claims.email ?? '',
    username: null,
    avatar: null,
    socialAttention: false,
    community: [],
    aiClip: null,
  };
  try {
    const db = await core();
    const [unread, me, social, settings] = await Promise.all([
      db.from('notifications').select('id', { count: 'exact', head: true }).eq('user_id', claims.sub).is('read_at', null),
      db.from('my_profile').select('username,display_name,avatar_path').maybeSingle(),
      db.from('social_accounts').select('status').eq('user_id', claims.sub),
      db.from('settings').select('key,value').in('key', ['public.community.links', 'public.flags.ai_clip', 'public.ai_clip.url']),
    ]);
    const cfg = Object.fromEntries((settings.data ?? []).map((r) => [r.key, r.value]));
    const statuses = (social.data ?? []).map((s) => s.status);
    return {
      unread: unread.count ?? 0,
      name: me.data?.display_name || me.data?.username || fallback.name,
      username: me.data?.username ?? null,
      avatar: publicUrl('avatars', me.data?.avatar_path),
      // Titik merah di tab Sosmed: belum ada akun terverifikasi, atau ada token yang perlu reconnect.
      socialAttention: !statuses.includes('verified') || statuses.some((s) => s === 'token_expired' || s === 'revoked'),
      community: communityLinks(cfg['public.community.links']),
      aiClip: cfg['public.flags.ai_clip'] === true ? httpsUrl(cfg['public.ai_clip.url']) : null,
    };
  } catch {
    return fallback;
  }
}
