/** Hasil Server Action: kode error mesin (message fungsi api) dipetakan ke teks di client (useErrorText). */
export type Result<T = object> = ({ ok: true } & T) | { ok: false; error: string; detail?: string };

export function fail(error: { message?: string; details?: string } | null | undefined): { ok: false; error: string; detail?: string } {
  return { ok: false, error: error?.message || 'generic', detail: error?.details || undefined };
}
