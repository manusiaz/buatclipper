// Sesi identity untuk seluruh app native. Gate sama dengan requireClipper web: tanpa sesi → login, admin → ditolak
// (akun admin terpisah, AA-20), consent clipper belum ada → onboarding (diselesaikan di accounts.{domain}).
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { decodeClaims, isAdmin, type Claims } from './claims';
import { clearCache } from './cache';
import { releaseLiveActivities, reopenLiveActivities } from './live-activity';
import { releasePush } from './push';
import { identity } from './supabase';
import { refreshWidgets } from './widget';
import { invalidateWidgetSnapshot } from './widget-load';

interface AuthState {
  ready: boolean;
  session: Session | null;
  claims: Claims | null;
  /** Ambil token baru (claim consent/kyc berubah setelah onboarding/KYC di web). */
  refresh: () => Promise<void>;
  /** false = token Live Activity iOS gagal dilepas (offline) → tetap login, tampilkan galat dan coba lagi. */
  signOut: () => Promise<boolean>;
}

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [ready, setReady] = useState(false);
  const [session, setSession] = useState<Session | null>(null);
  const signingOut = useRef(false);

  useEffect(() => {
    identity.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    // Login baru membuka lagi pendaftaran token Live Activity — bukan event dari sesi yang sedang keluar.
    const { data } = identity.auth.onAuthStateChange((e, s) => {
      if (e === 'SIGNED_IN' && !signingOut.current) reopenLiveActivities();
      setSession(s);
    });
    return () => data.subscription.unsubscribe();
  }, []);

  const refresh = useCallback(async () => {
    const { data } = await identity.auth.refreshSession();
    if (data.session) setSession(data.session);
  }, []);
  const signOut = useCallback(async () => {
    // Lepas semua yang terikat perangkat selagi masih login (RLS), supaya HP bersama tidak terus menampilkan akun lama:
    // token Live Activity iOS dulu (tak bisa dicabut dari app → gagal = batal keluar, sebelum push sempat dimatikan),
    // lalu push, muatan widget yang sedang jalan, cache; widget dirender ulang tanpa sesi.
    signingOut.current = true;
    try {
      try {
        await releaseLiveActivities();
      } catch {
        return false;
      }
      await releasePush();
      invalidateWidgetSnapshot();
      await clearCache();
      await identity.auth.signOut({ scope: 'local' });
      setSession(null);
      void refreshWidgets();
      return true;
    } finally {
      signingOut.current = false;
    }
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
