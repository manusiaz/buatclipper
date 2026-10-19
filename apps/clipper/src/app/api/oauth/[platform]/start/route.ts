import { NextResponse, type NextRequest } from 'next/server';
import { hosts } from '@clipper/auth';
import { invokeFunction, requireClipper } from '@clipper/auth/server';
import { isPlatform } from '@/features/lib/pure';
import { cookieOptions, encodeState, internalNext, redirectUri, STATE_COOKIE } from '@/features/social/oauth';

// C1.5: minta URL izin platform ke core/social (authorize), simpan state + code_verifier, lalu ke halaman resmi platform.
export async function GET(request: NextRequest, { params }: { params: Promise<{ platform: string }> }) {
  await requireClipper();
  const { platform } = await params;
  const back = (q: string) => NextResponse.redirect(new URL(`/social?${q}`, hosts.app));
  if (!isPlatform(platform)) return back('error=bad_request');
  const next = internalNext(request.nextUrl.searchParams.get('next'));
  const pageId = request.nextUrl.searchParams.get('page_id')?.slice(0, 64) || undefined;
  const r = await invokeFunction<{ url: string; state: string; code_verifier?: string }>('core', 'social', {
    action: 'authorize',
    platform,
    redirect_uri: redirectUri(platform),
  });
  if (!r.ok || !r.data?.url || !r.data.state) {
    const q = new URLSearchParams({ error: r.ok ? 'oauth_failed' : r.error });
    if (next) q.set('next', next);
    return back(q.toString());
  }
  let target: URL;
  try {
    target = new URL(r.data.url);
    if (target.protocol !== 'https:') throw new Error('insecure');
  } catch {
    return back('error=oauth_failed');
  }
  const res = NextResponse.redirect(target);
  res.cookies.set(
    STATE_COOKIE,
    encodeState({ state: r.data.state, verifier: r.data.code_verifier, platform, next, pageId }),
    cookieOptions(),
  );
  return res;
}
