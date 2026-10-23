import { NextResponse, type NextRequest } from 'next/server';
import { hosts } from '@clipper/auth';
import { invokeFunction, requireClipper } from '@clipper/auth/server';
import { isPlatform } from '@clipper/clipper-lib/pure';
import { APP_RETURN, cookieOptions, decodeState, redirectUri, STATE_COOKIE, verifyState } from '@/features/social/oauth';

// Platform → app.{domain}/api/oauth/[platform]/callback: cek state (constant-time) → creator/social connect → /social.
export async function GET(request: NextRequest, { params }: { params: Promise<{ platform: string }> }) {
  await requireClipper();
  const { platform } = await params;
  const sp = request.nextUrl.searchParams;
  const saved = decodeState(request.cookies.get(STATE_COOKIE)?.value);
  const done = (q: URLSearchParams) => {
    // Dibuka dari app native (next = /app-return): hasil langsung kembali ke app lewat clipper://social.
    const toApp = saved?.next === APP_RETURN;
    if (saved?.next && !toApp) q.set('next', saved.next);
    const res = NextResponse.redirect(new URL(`${toApp ? APP_RETURN : '/social'}?${q}`, hosts.app));
    res.cookies.set(STATE_COOKIE, '', { ...cookieOptions(), maxAge: 0 });
    return res;
  };
  if (!isPlatform(platform)) return done(new URLSearchParams({ error: 'bad_request' }));
  if (!verifyState(saved, platform, sp.get('state'))) return done(new URLSearchParams({ error: 'state_mismatch' }));
  // Batal di halaman platform (access_denied, user_cancelled, …).
  if (sp.get('error') || sp.get('error_code')) return done(new URLSearchParams({ error: 'oauth_cancelled', platform }));
  const code = sp.get('code');
  if (!code || code.length > 2048) return done(new URLSearchParams({ error: 'oauth_failed', platform }));

  const r = await invokeFunction<{ platform: string; handle: string }>('creator', 'social', {
    action: 'connect',
    platform,
    code,
    redirect_uri: redirectUri(platform),
    ...(saved.verifier ? { code_verifier: saved.verifier } : {}),
    ...(saved.pageId ? { page_id: saved.pageId } : {}),
  });
  if (r.ok) return done(new URLSearchParams({ connected: platform, handle: r.data.handle ?? '' }));
  const q = new URLSearchParams({ error: r.error, platform });
  // Facebook dengan >1 Page: daftar Page (id, nama) dikirim ke picker; pilih → authorize ulang dengan page_id.
  if (r.error === 'page_ambiguous' && Array.isArray(r.detail)) {
    const pages = (r.detail as { id?: unknown; name?: unknown }[])
      .slice(0, 20)
      .map((p) => ({ id: String(p.id ?? '').slice(0, 64), name: String(p.name ?? '').slice(0, 80) }))
      .filter((p) => p.id);
    q.set('pages', Buffer.from(JSON.stringify(pages)).toString('base64url'));
  }
  return done(q);
}
