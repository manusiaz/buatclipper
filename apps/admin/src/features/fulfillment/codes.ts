export const MAX_CODES = 10_000; // batas api.upload_reward_codes per panggilan

/** Kode voucher dari teks/CSV: pisah baris, koma, titik koma, atau tab; trim; buang kosong & duplikat. */
export function parseCodes(raw: string): string[] {
  return [...new Set(raw.split(/[\r\n,;\t]+/).map((c) => c.trim().replace(/^"(.*)"$/, '$1').trim()).filter(Boolean))];
}
