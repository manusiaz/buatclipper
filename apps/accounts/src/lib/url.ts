export type SearchParams = Promise<Record<string, string | string[] | undefined>>;

/** Nilai query pertama (Next memberi array kalau parameter berulang). */
export const one = (v: string | string[] | undefined): string | undefined => (Array.isArray(v) ? v[0] : v);

/** Tambah/ganti query di URL tujuan, relatif ("/kyc") atau absolut, tanpa membuang query yang sudah ada. */
export function withParams(target: string, params: Record<string, string | null | undefined>): string {
  const relative = target.startsWith('/');
  const url = new URL(target, 'http://relative.invalid');
  for (const [k, v] of Object.entries(params)) if (v) url.searchParams.set(k, v);
  return relative ? `${url.pathname}${url.search}${url.hash}` : url.toString();
}

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
