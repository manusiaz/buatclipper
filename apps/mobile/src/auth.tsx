// Sesi identity untuk seluruh app native. Gate sama dengan requireClipper web: tanpa sesi → login, admin → ditolak
// (akun admin terpisah, AA-20), consent clipper belum ada → onboarding (diselesaikan di accounts.{domain}).
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { decodeClaims, isAdmin, type Claims } from './claims';
import { releasePush } from './push';
import { identity } from './supabase';

interface AuthState {
  ready: boolean;
  session: Session | null;
  claims: Claims | null;
  /** Ambil token baru (claim consent/kyc berubah setelah onboarding/KYC di web). */
  refresh: () => Promise<void>;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [ready, setReady] = useState(false);
  const [session, setSession] = useState<Session | null>(null);

  useEffect(() => {
    identity.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data } = identity.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => data.subscription.unsubscribe();
  }, []);

  const refresh = useCallback(async () => {
    const { data } = await identity.auth.refreshSession();
    if (data.session) setSession(data.session);
  }, []);
  const signOut = useCallback(async () => {
    // Lepas push perangkat ini selagi masih login (RLS): HP bersama tidak terus menerima notifikasi akun lama.
    await releasePush();
    await identity.auth.signOut({ scope: 'local' });
    setSession(null);
  }, []);

  const value = useMemo(() => {
    const claims = decodeClaims(session?.access_token);
    return { ready, session: isAdmin(claims) ? null : session, claims: isAdmin(claims) ? null : claims, refresh, signOut };
  }, [ready, session, refresh, signOut]);
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('AuthProvider belum dipasang');
  return ctx;
}
