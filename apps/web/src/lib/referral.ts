// Link referral {domain}/?ref=<kode> (J-C5): kode disimpan 30 hari di cookie .{domain}; onboarding accounts mengirimnya ke
// api.ensure_profile project creator (hanya profil baru). Kode = 8 karakter dari api.my_referral_code.
export const REF_COOKIE = 'clipper_ref';
export const REF_MAX_AGE = 60 * 60 * 24 * 30;

export function refCode(raw: string | null | undefined): string | null {
  const code = raw?.trim().toLowerCase() ?? '';
  return /^[a-z0-9]{8}$/.test(code) ? code : null;
}
