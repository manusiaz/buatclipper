import { NextResponse, type NextRequest } from 'next/server';
import { identityServer, invokeFunction } from '@clipper/auth/server';
import { handoffTarget, type Redeemed } from '@/lib/handoff';

/**
 * GET /handoff?code=…[&next=…] — app native membuka halaman web sudah login: kode sekali pakai (60 detik) dari identity
 * session-handoff ditukar jadi sesi SSO (cookie .{domain}), lalu ke next. Hanya publishable key (invarian 4).
 */
export async function GET(request: NextRequest) {
  const sp = request.nextUrl.searchParams;
  const to = await handoffTarget(sp.get('code'), sp.get('next'), {
    redeem: (code) => invokeFunction<Redeemed>('identity', 'session-handoff', { action: 'redeem', code }, 'public'),
    verify: async (tokenHash) => {
      const supabase = await identityServer('sso');
      const { error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type: 'magiclink' });
      return !error;
    },
  });
  const res = NextResponse.redirect(new URL(to, request.url));
  res.headers.set('Cache-Control', 'no-store');
  return res;
}
