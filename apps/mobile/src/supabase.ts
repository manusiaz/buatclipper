// Client identity (login OTP, sesi di SecureStore) + core (JWT identity → RLS core = user ini, PRD §15.6) + Edge Function.
// Sama dengan app Next: tidak ada secret di app, semua lewat publishable key + JWT user.
import { createClient } from '@supabase/supabase-js';
import { AppState, Platform } from 'react-native';
import type { Database as CoreDb } from '@clipper/db-core';
import type { Database as IdentityDb } from '@clipper/db-identity';
import { env } from './env';
import { secureStorage } from './storage';

export const identity = createClient<IdentityDb>(env.identityUrl, env.identityKey, {
  auth: { storage: secureStorage, persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
});

// Refresh token hanya saat app di depan (rekomendasi supabase-js untuk RN).
if (Platform.OS !== 'web') {
  AppState.addEventListener('change', (s) => (s === 'active' ? identity.auth.startAutoRefresh() : identity.auth.stopAutoRefresh()));
}

export const accessToken = async (): Promise<string | null> => (await identity.auth.getSession()).data.session?.access_token ?? null;

export const core = createClient<CoreDb, 'api'>(env.coreUrl, env.coreKey, { db: { schema: 'api' }, accessToken });
// Storage project brand: aset brief campaign (signed URL, policy campaign_assets_read).
export const brandStorage = createClient(env.brandDbUrl, env.brandDbKey, { accessToken }).storage;
export const identityApi = identity.schema('api');

export type FnResult<T> = { ok: true; data: T } | { ok: false; error: string; detail?: unknown; status: number };

/** Edge Function core/identity dengan JWT user (tanpa Origin = jalur server-ke-server di _shared/http.ts). */
export async function invoke<T = unknown>(project: 'core' | 'identity', name: string, body: unknown): Promise<FnResult<T>> {
  const token = await accessToken();
  if (!token) return { ok: false, error: 'auth:no_session', status: 401 };
  const [base, key] = project === 'core' ? [env.coreUrl, env.coreKey] : [env.identityUrl, env.identityKey];
  let res: Response;
  try {
    res = await fetch(`${base}/functions/v1/${name}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${token}`, apikey: key },
      body: JSON.stringify(body),
    });
  } catch {
    return { ok: false, error: 'network', status: 0 };
  }
  const json = (await res.json().catch(() => null)) as Record<string, unknown> | null;
  if (json && typeof json.ok === 'boolean') {
    if (json.ok) return { ok: true, data: json.data as T };
    const e = (json.error ?? {}) as { code?: string };
    return { ok: false, error: e.code ?? 'generic', status: res.status };
  }
  if (!res.ok) return { ok: false, error: String(json?.error ?? 'generic'), detail: json?.detail, status: res.status };
  return { ok: true, data: json as T };
}

/** URL publik bucket: campaign-covers (storage brand), avatars (storage admin) — sama dengan publicUrl app Next. */
export function publicUrl(bucket: 'campaign-covers' | 'avatars', path: string | null | undefined): string | null {
  if (!path) return null;
  return `${bucket === 'campaign-covers' ? env.brandDbUrl : env.coreUrl}/storage/v1/object/public/${bucket}/${path.split('/').map(encodeURIComponent).join('/')}`;
}
