// Aturan login OTP murni (tanpa Next): dipakai Server Action web (actions.ts) dan app native (apps/mobile).
export const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** Error Auth identity → kunci auth.errors.* (pesan sama di web & native). */
export function mapAuthError(e: { code?: string; status?: number; message?: string } | null): string {
  const code = e?.code ?? '';
  if (code.includes('rate_limit') || e?.status === 429) return 'rate_limited';
  if (code.includes('captcha')) return 'captcha';
  if (code === 'otp_expired' || code === 'invalid_credentials' || code === 'bad_jwt') return 'invalid_code';
  if (code === 'mfa_verification_failed') return 'mfa_invalid';
  return 'generic';
}
