import { NextResponse, type NextRequest } from 'next/server';
import { requireClipper } from '@clipper/auth/server';

// Akhir alur web yang dibuka app native (OAuth sosmed): kembali ke app lewat skema clipper:// — browser in-app
// (auth session) menutup sendiri. Hanya parameter hasil yang diteruskan; tujuan tetap, bukan dari query.
const KEEP = ['connected', 'handle', 'error', 'platform', 'pages'] as const;

export async function GET(request: NextRequest) {
  await requireClipper();
  const out = new URLSearchParams();
  for (const k of KEEP) {
    const v = request.nextUrl.searchParams.get(k);
    if (v) out.set(k, v.slice(0, 2048));
  }
  return NextResponse.redirect(`clipper://social?${out}`, 302);
}
