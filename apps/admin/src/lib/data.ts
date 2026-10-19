// Helper baca Data API di Server Component: error baca dilempar ke error.tsx segmen.
type Res<T> = { data: T | null; error: { message: string } | null };

export function must<T>(r: Res<T>): T {
  if (r.error) throw new Error(r.error.message);
  return r.data as T;
}

export function rows<T>(r: Res<T[]>): T[] {
  if (r.error) throw new Error(r.error.message);
  return r.data ?? [];
}

/** numeric Postgres dikirim sebagai string (PostgREST menerimanya) supaya uang tidak lewat float. */
export const numeric = (v: string) => v as unknown as number;

export const uniq = <T>(xs: (T | null | undefined)[]): T[] => [...new Set(xs.filter((x): x is T => x != null))];

export type SearchParams = Record<string, string | string[] | undefined>;

export const param = (sp: SearchParams, key: string): string => {
  const v = sp[key];
  return (Array.isArray(v) ? v[0] : v)?.trim() ?? '';
};

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (v: string | null | undefined): v is string => !!v && UUID_RE.test(v);

/** Escape nilai untuk filter PostgREST ilike di dalam or(...). */
export const likeTerm = (q: string) => `%${q.replace(/[%_,()\\*]/g, ' ').trim()}%`;
