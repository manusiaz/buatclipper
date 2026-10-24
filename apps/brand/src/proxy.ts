import type { NextRequest } from 'next/server';
import { clipperProxy } from '@clipper/auth/proxy';

export function proxy(request: NextRequest) {
  return clipperProxy(request, 'brand', []);
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|icon.svg|icons/|images/|sw.js|manifest.webmanifest|robots.txt|sitemap.xml).*)'],
};
