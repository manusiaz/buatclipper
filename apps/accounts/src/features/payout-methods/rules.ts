// Kode bank = kode channel Xendit tanpa awalan "ID_" (xenditChannelCode di identity _shared/disburse.ts).
export type MethodKind = 'bank' | 'ewallet';

export const BANKS = [
  { code: 'BCA', name: 'BCA' },
  { code: 'BRI', name: 'BRI' },
  { code: 'MANDIRI', name: 'Bank Mandiri' },
  { code: 'BNI', name: 'BNI' },
  { code: 'BSI', name: 'Bank Syariah Indonesia (BSI)' },
  { code: 'CIMB', name: 'CIMB Niaga' },
  { code: 'PERMATA', name: 'Bank Permata' },
  { code: 'DANAMON', name: 'Bank Danamon' },
  { code: 'BTN', name: 'BTN' },
  { code: 'OCBC', name: 'OCBC' },
  { code: 'MAYBANK', name: 'Maybank Indonesia' },
  { code: 'PANIN', name: 'Panin Bank' },
  { code: 'MEGA', name: 'Bank Mega' },
  { code: 'BJB', name: 'Bank BJB' },
  { code: 'JAGO', name: 'Bank Jago' },
  { code: 'SEABANK', name: 'SeaBank' },
] as const;

export const EWALLETS = [
  { code: 'GOPAY', name: 'GoPay' },
  { code: 'OVO', name: 'OVO' },
  { code: 'DANA', name: 'DANA' },
  { code: 'SHOPEEPAY', name: 'ShopeePay' },
  { code: 'LINKAJA', name: 'LinkAja' },
] as const;

export const bankName = (code: string) => [...BANKS, ...EWALLETS].find((b) => b.code === code)?.name ?? code;

/** Sama dengan normalizeAccountNo member-data: bank 5–20 digit; e-wallet nomor HP 08… (+62/62 → 0). null = tidak valid. */
export function normalizeAccountNo(kind: MethodKind, raw: string): string | null {
  let d = raw.replace(/[\s.+-]/g, '');
  if (!/^\d+$/.test(d)) return null;
  if (kind === 'ewallet') {
    if (d.startsWith('62')) d = `0${d.slice(2)}`;
    return /^08\d{8,12}$/.test(d) ? d : null;
  }
  return d.length >= 5 && d.length <= 20 ? d : null;
}

/** Perbandingan nama pemilik vs nama KYC (normalizeName identity: trim, spasi tunggal, huruf kecil). */
export const sameName = (a: string, b: string) => {
  const n = (s: string) => s.trim().replace(/\s+/g, ' ').toLowerCase();
  return n(a) === n(b);
};

export interface RecipientField {
  key: string;
  label?: string;
  required: boolean;
}

const truthy = (v: unknown) => v === true || v === 'true';

/** Field PII dari recipient_schema reward type [{key, label, pii, required}] — nilainya disimpan di identity (E-29). */
export function piiFields(schema: unknown): RecipientField[] {
  if (!Array.isArray(schema)) return [];
  return schema.flatMap((f) => {
    if (!f || typeof f !== 'object') return [];
    const { key, label, pii, required } = f as Record<string, unknown>;
    if (!truthy(pii) || typeof key !== 'string' || !/^[a-z][a-z0-9_]{0,39}$/.test(key)) return [];
    return [{ key, label: typeof label === 'string' && label.trim() ? label : undefined, required: required !== false && required !== 'false' }];
  });
}
