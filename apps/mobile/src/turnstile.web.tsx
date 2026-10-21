// Expo web (uji lokal tanpa CAPTCHA): Turnstile dinonaktifkan — web produksi memakai packages/auth LoginForm.
export const turnstileSiteKey = '';
export function Turnstile(_: { round: number; onToken: (t: string | undefined) => void }) {
  return null;
}
