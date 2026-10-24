export const CONSENT_KINDS = ['tos_clipper', 'tos_brand', 'privacy', 'age_18_plus', 'kyc', 'share_with_brand'] as const;
export type ConsentKind = (typeof CONSENT_KINDS)[number];

export interface ConsentRow {
  kind: string | null;
  version: string | null;
  granted_at: string | null;
  revoked_at: string | null;
}

export interface ConsentState {
  kind: ConsentKind;
  active: boolean;
  version: string | null;
  grantedAt: string | null;
  revokedAt: string | null;
}

/**
 * Satu baris per jenis (urutan CONSENT_KINDS): baris aktif terbaru, kalau semua dicabut → baris terbaru.
 * share_with_brand selalu ada supaya user bisa memberi izin dari halaman privasi.
 */
export function consentSummary(rows: ConsentRow[]): ConsentState[] {
  const sorted = [...rows].sort((a, b) => (b.granted_at ?? '').localeCompare(a.granted_at ?? ''));
  return CONSENT_KINDS.flatMap((kind) => {
    const mine = sorted.filter((r) => r.kind === kind);
    const row = mine.find((r) => !r.revoked_at) ?? mine[0];
    if (!row) {
      return kind === 'share_with_brand' ? [{ kind, active: false, version: null, grantedAt: null, revokedAt: null }] : [];
    }
    return [{ kind, active: !row.revoked_at, version: row.version, grantedAt: row.granted_at, revokedAt: row.revoked_at }];
  });
}
