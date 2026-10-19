import type { NextRequest } from 'next/server';
import { clipperProxy } from '@clipper/auth/proxy';

export function proxy(request: NextRequest) {
  return clipperProxy(request, 'clipper', ['/login', '/auth', '/offline']);
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico|icons/|images/|sw.js|manifest.webmanifest|robots.txt|sitemap.xml).*)'],
};
