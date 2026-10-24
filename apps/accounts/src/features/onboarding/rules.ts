// Aturan onboarding yang sama dengan CHECK market.profiles (username) & api.record_consent (versi legal terbaru).
export type Role = 'clipper' | 'brand';
export type LegalKind = 'tos_clipper' | 'tos_brand' | 'privacy';
export interface LegalDoc {
  version: string;
  url: string;
}

export const USERNAME_RE = /^(?!deleted_)[a-z0-9_.]{3,30}$/; // deleted_ = profil yang dihapus (direservasi DB creator)
export const DISPLAY_NAME_MAX = 50;

export const normalizeUsername = (s: string) => s.trim().toLowerCase();

/** role dari query; kosong → tebak dari next (URL brand = brand). */
export function roleOf(role: string | undefined, next: string | undefined, brandHost: string): Role {
  if (role === 'clipper' || role === 'brand') return role;
  try {
    return next && new URL(next).origin === new URL(brandHost).origin ? 'brand' : 'clipper';
  } catch {
    return 'clipper';
  }
}

/** Username awal dari email ("Rani.Putri+x@…" → "rani.putri"). Username otomatis anggota brand (m_<hex>) tidak dipakai. */
export function initialUsername(existing: string | null | undefined, email: string | null | undefined): string {
  if (existing && !/^m_[0-9a-f]{12}$/.test(existing)) return existing;
  const base = (email ?? '').split('@')[0]!.split('+')[0]!.toLowerCase().replace(/[^a-z0-9_.]/g, '').slice(0, 30);
  if (base.length >= 3) return base;
  return existing ?? '';
}

/** Saran username saat yang diketik sudah dipakai. */
export function usernameCandidates(base: string, rand: () => number = Math.random): string[] {
  const b = base.slice(0, 25);
  const n = () => String(Math.floor(rand() * 900) + 100);
  return [...new Set([`${b}${n()}`, `${b}_${n()}`, `${b}.id`, `${b}_clips`])].filter((c) => USERNAME_RE.test(c));
}

/** Versi terbit terbaru per jenis dokumen (sama dengan max(version) where published_at <= now di record_consent). */
export function latestLegal(
  rows: { kind: string | null; version: string | null; url: string | null; published_at: string | null }[],
  now: Date = new Date(),
): Partial<Record<LegalKind, LegalDoc>> {
  const out: Partial<Record<LegalKind, LegalDoc>> = {};
  for (const r of rows) {
    if (!r.kind || !r.version || !r.url || !r.published_at || new Date(r.published_at) > now) continue;
    const kind = r.kind as LegalKind;
    if (!out[kind] || out[kind]!.version < r.version) out[kind] = { version: r.version, url: r.url };
  }
  return out;
}
