'use server';

import { cookies } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { getAuth, requireClipper } from '@clipper/auth/server';
import { identityApi } from '@clipper/db-identity';
import { LOCALE_COOKIE, locales, type Locale } from '@clipper/i18n';
import { core, fail, ok, type Result } from '../lib/server';

/** F-C18: cookie NEXT_LOCALE berlaku di semua subdomain (Domain = NEXT_PUBLIC_COOKIE_DOMAIN). */
export async function setLocale(locale: Locale): Promise<Result> {
  if (!(locales as readonly string[]).includes(locale)) return fail('invalid:locale');
  (await cookies()).set(LOCALE_COOKIE, locale, {
    domain: process.env.NEXT_PUBLIC_COOKIE_DOMAIN || undefined,
    path: '/',
    maxAge: 60 * 60 * 24 * 365,
    sameSite: 'lax',
    secure: (process.env.NEXT_PUBLIC_APP_URL ?? '').startsWith('https://'),
  });
  revalidatePath('/', 'layout');
  return ok(null);
}

/** E-34 email promosi. Update dulu (grant update email_promotions), baris belum ada → insert (grant insert). */
export async function setEmailPromotions(on: boolean): Promise<Result> {
  const { claims } = await requireClipper();
  const db = await core();
  const now = new Date().toISOString();
  const up = await db.from('notification_prefs').update({ email_promotions: !!on, updated_at: now }).eq('user_id', claims.sub).select('user_id');
  if (up.error) return fail(up.error.message);
  if (!up.data?.length) {
    const ins = await db.from('notification_prefs').insert({ user_id: claims.sub, email_promotions: !!on });
    if (ins.error) return fail(ins.error.message);
  }
  revalidatePath('/settings');
  return ok(null);
}

/** C3.2: langganan web push perangkat ini → identity api.save_push_subscription (E-36). */
export async function savePush(sub: { endpoint: string; p256dh: string; auth: string }): Promise<Result> {
  await requireClipper();
  const valid = (v: unknown, max: number) => typeof v === 'string' && v.length > 0 && v.length <= max;
  if (!valid(sub?.endpoint, 2000) || !sub.endpoint.startsWith('https://') || !valid(sub.p256dh, 200) || !valid(sub.auth, 100)) {
    return fail('invalid:subscription');
  }
  const { supabase } = await getAuth('sso');
  const { error } = await identityApi(supabase).rpc('save_push_subscription', {
    p_endpoint: sub.endpoint,
    p_p256dh: sub.p256dh,
    p_auth: sub.auth,
  });
  if (error) return fail(error.message);
  revalidatePath('/settings');
  return ok(null);
}

export async function deletePush(endpoint: string): Promise<Result> {
  await requireClipper();
  if (typeof endpoint !== 'string' || !endpoint.startsWith('https://')) return fail('invalid:subscription');
  const { supabase } = await getAuth('sso');
  const { error } = await identityApi(supabase).from('push_subscriptions').delete().eq('endpoint', endpoint);
  if (error) return fail(error.message);
  revalidatePath('/settings');
  return ok(null);
}
