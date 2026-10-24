import { coreServer, getAuth, invokeFunction } from '@clipper/auth/server';

const PAGE = 1000; // max_rows default PostgREST

async function all<T>(page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>) {
  const out: T[] = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await page(from, from + PAGE - 1);
    if (error) throw new Error(error.message);
    out.push(...(data ?? []));
    if (!data || data.length < PAGE) return out;
  }
}

export type MyDataResult = { ok: true; data: unknown } | { ok: false; error: string; status: number };

/**
 * "Unduh data saya" (C2.4, UU PDP hak akses): identity member-data (NIK & rekening didekripsi untuk pemiliknya) + baris
 * core milik sendiri (RLS) jadi satu JSON. Tidak ada alur lintas DB baru: keduanya dibaca dengan JWT user.
 */
export async function buildMyData(): Promise<MyDataResult> {
  const { claims } = await getAuth('sso');
  if (!claims) return { ok: false, error: 'auth:no_session', status: 401 };
  const identity = await invokeFunction<Record<string, unknown>>('identity', 'member-data', { action: 'download_my_data' });
  if (!identity.ok) return { ok: false, error: identity.error, status: identity.status || 502 };

  const core = await coreServer();
  const uid = claims.sub;
  try {
    const [profile, claimRows, submissions, socialAccounts, walletEntries, payouts, fulfillments, notifications, referrals, scoreEvents] =
      await Promise.all([
        core.from('my_profile').select('*').maybeSingle(),
        all((a, b) => core.from('claims').select('*').eq('user_id', uid).order('created_at').order('id').range(a, b)),
        all((a, b) => core.from('submissions').select('*').eq('user_id', uid).order('created_at').order('id').range(a, b)),
        all((a, b) => core.from('social_accounts').select('*').eq('user_id', uid).order('created_at').order('id').range(a, b)),
        all((a, b) => core.from('wallet_entries').select('*').eq('user_id', uid).order('created_at').order('id').range(a, b)),
        all((a, b) => core.from('payouts').select('*').eq('user_id', uid).order('created_at').order('id').range(a, b)),
        all((a, b) => core.from('fulfillments').select('*').eq('user_id', uid).order('created_at').order('id').range(a, b)),
        all((a, b) => core.from('notifications').select('*').eq('user_id', uid).order('created_at').order('id').range(a, b)),
        all((a, b) => core.from('referrals').select('*').order('created_at').order('referred_id').range(a, b)),
        all((a, b) => core.from('score_events').select('*').eq('user_id', uid).order('created_at').order('id').range(a, b)),
      ]);
    if (profile.error) throw new Error(profile.error.message);
    return {
      ok: true,
      data: {
        generated_at: new Date().toISOString(),
        user_id: uid,
        email: claims.email ?? null,
        identity: identity.data,
        core: {
          profile: profile.data,
          claims: claimRows,
          submissions,
          social_accounts: socialAccounts,
          wallet_entries: walletEntries,
          payouts,
          fulfillments,
          notifications,
          referrals,
          score_events: scoreEvents,
        },
      },
    };
  } catch {
    return { ok: false, error: 'generic', status: 502 };
  }
}
