// Akses data server-side bersama semua halaman clipper (RSC & Server Action).
import { getLocale, getTranslations } from 'next-intl/server';
import { coreServer } from '@clipper/auth/server';
import { platformLabel, type Platform, type UiLocale } from '@clipper/ui';
import { errorKey, isPlatform } from '@clipper/clipper-lib/pure';

export type Fail = { ok: false; code: string; message: string };
export type Result<T = null> = { ok: true; data: T } | Fail;

export const ok = <T,>(data: T): Result<T> => ({ ok: true, data });

export const core = () => coreServer('sso');

export async function uiLocale(): Promise<UiLocale> {
  return (await getLocale()) === 'en' ? 'en' : 'id';
}

/** Kode error RPC/Edge Function → pesan terjemahan (namespace errors, lalu clipper.errors, lalu generic). */
export async function errorText(raw: string | null | undefined, detail?: unknown): Promise<string> {
  const { key, param } = errorKey(raw, detail, (p) => (isPlatform(p) ? platformLabel(p as Platform) : p));
  const [tErr, tApp] = await Promise.all([getTranslations('errors'), getTranslations('clipper.errors')]);
  if (tErr.has(key)) return tErr(key, { param });
  if (tApp.has(key)) return tApp(key, { param });
  return tErr('generic');
}

export async function fail(raw: string | null | undefined, detail?: unknown): Promise<Fail> {
  return { ok: false, code: raw || 'generic', message: await errorText(raw, detail) };
}

/** Cap & hold yang berlaku untuk clipper ini per platform (api.my_clip_terms = ketentuan accrual & release). */
export async function myClipTerms(): Promise<Record<string, { cap_pct: number; hold_days: number }>> {
  const db = await core();
  const { data } = await db.rpc('my_clip_terms');
  return data && typeof data === 'object' && !Array.isArray(data) ? (data as Record<string, { cap_pct: number; hold_days: number }>) : {};
}

/** Config public.* (ops.settings, terbaca semua user). */
export async function readSettings(keys: string[]): Promise<Record<string, unknown>> {
  const db = await core();
  const { data } = await db.from('settings').select('key,value').in('key', keys);
  return Object.fromEntries((data ?? []).map((r) => [r.key, r.value]));
}

/** Bucket publik core (campaign-covers, avatars). */
export function publicUrl(bucket: 'campaign-covers' | 'avatars', path: string | null | undefined): string | null {
  if (!path) return null;
  const base = process.env.NEXT_PUBLIC_CORE_URL;
  return `${base}/storage/v1/object/public/${bucket}/${path.split('/').map(encodeURIComponent).join('/')}`;
}

export interface RewardUnit {
  id: string;
  code: string;
  name: string;
  kind: string;
  unit_label: string;
  decimals: number;
  idr_value_per_unit: number;
  fulfillment: string;
  recipient_schema: unknown;
}

/** Reward type (E-07, publik) by id. */
export async function rewardTypes(ids: Iterable<string>): Promise<Map<string, RewardUnit>> {
  const list = [...new Set(ids)].filter(Boolean);
  if (!list.length) return new Map();
  const db = await core();
  const { data } = await db
    .from('reward_types')
    .select('id,code,name,kind,unit_label,decimals,idr_value_per_unit,fulfillment,recipient_schema')
    .in('id', list);
  return new Map(
    (data ?? []).map((r) => [
      r.id!,
      {
        id: r.id!,
        code: r.code ?? '',
        name: r.name ?? '',
        kind: r.kind ?? '',
        unit_label: r.unit_label ?? '',
        decimals: r.decimals ?? 0,
        idr_value_per_unit: Number(r.idr_value_per_unit ?? 0),
        fulfillment: r.fulfillment ?? '',
        recipient_schema: r.recipient_schema,
      },
    ]),
  );
}
