import type { NextRequest } from 'next/server';
import { clipperProxy } from '@clipper/auth/proxy';
import { REF_COOKIE, REF_MAX_AGE, refCode } from '@/lib/referral';

export async function proxy(request: NextRequest) {
  const response = await clipperProxy(request, 'web');
  const ref = refCode(request.nextUrl.searchParams.get('ref'));
  if (ref) {
    response.cookies.set(REF_COOKIE, ref, {
      domain: process.env.NEXT_PUBLIC_COOKIE_DOMAIN || undefined,
      path: '/',
      maxAge: REF_MAX_AGE,
      sameSite: 'lax',
      httpOnly: true,
      secure: request.nextUrl.protocol === 'https:',
    });
  }
  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|icon.svg|icons/|images/|sw.js|manifest.webmanifest|robots.txt|sitemap.xml).*)'],
};
