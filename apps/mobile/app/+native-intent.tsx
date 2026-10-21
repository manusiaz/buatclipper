// URL masuk dari sistem (universal link / App Link app.{domain}, clipper://…, share extension iOS) → rute native.
// Link web dipetakan nativeRoute (sama dengan tap notifikasi); share extension (clipper://dataUrl=…) dibaca
// ShareIntentGate, jadi router tidak berpindah. Tanpa padanan: buka app di layar awal (bukan "tidak ditemukan").
import { nativeRoute } from '@/links';

export function redirectSystemPath({ path, initial }: { path: string; initial: boolean }): string | null {
  const fallback = initial ? '/' : null;
  try {
    if (path.includes('dataUrl=')) return fallback;
    if (/^https?:\/\//i.test(path)) return nativeRoute(path) ?? fallback;
    return path;
  } catch {
    return fallback;
  }
}
