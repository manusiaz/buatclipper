// Claim JWT identity (custom_access_token_hook): dibaca dari access token untuk gate UI. Otorisasi tetap di RLS/fungsi.
export interface Claims {
  sub: string;
  email?: string;
  app_roles?: string[];
  kyc?: 'none' | 'pending' | 'approved' | 'rejected';
  consent_ok?: { clipper?: boolean; brand?: boolean };
  exp?: number;
}

export function decodeClaims(token: string | null | undefined): Claims | null {
  const part = token?.split('.')[1];
  if (!part) return null;
  try {
    const b64 = part.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(part.length / 4) * 4, '=');
    const json = decodeURIComponent(
      [...atob(b64)].map((c) => '%' + c.charCodeAt(0).toString(16).padStart(2, '0')).join(''),
    );
    const c = JSON.parse(json) as Claims;
    return typeof c.sub === 'string' ? c : null;
  } catch {
    return null;
  }
}

/** Akun admin wajib terpisah (AA-20): ditolak di app clipper, sama dengan requireClipper. */
export const isAdmin = (c: Claims | null) => !!c?.app_roles?.some((r) => r.startsWith('admin_'));
