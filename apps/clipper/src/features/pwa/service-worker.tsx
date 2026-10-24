'use client';

import { useEffect } from 'react';

/** Daftarkan public/sw.js (push + fallback offline, F-C14). Same-origin, jadi lolos CSP script-src 'self'. */
export function ServiceWorker() {
  useEffect(() => {
    if (!('serviceWorker' in navigator)) return;
    navigator.serviceWorker.register('/sw.js', { scope: '/', updateViaCache: 'none' }).catch(() => {});
  }, []);
  return null;
}
