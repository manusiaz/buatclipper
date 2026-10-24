// Offline duluan (DS Android 03 "Saldo, riwayat, sama campaign tersimpan. Tampilin 'terakhir update' kalau offline"):
// hasil query terakhir per user di AsyncStorage. Dihapus saat keluar (HP bersama). Bukan data rahasia: saldo &
// daftar yang sama dengan layar; token sesi tetap di SecureStore.
import AsyncStorage from '@react-native-async-storage/async-storage';

const PREFIX = 'clipper.cache.';

const replacer = (_k: string, v: unknown) => (v instanceof Map ? { __map: [...v] } : v);
const reviver = (_k: string, v: unknown) =>
  v && typeof v === 'object' && Array.isArray((v as { __map?: unknown }).__map) ? new Map((v as { __map: [unknown, unknown][] }).__map) : v;

export async function readCache<T>(key: string): Promise<{ at: number; data: T } | null> {
  try {
    const raw = await AsyncStorage.getItem(PREFIX + key);
    return raw ? (JSON.parse(raw, reviver) as { at: number; data: T }) : null;
  } catch {
    return null;
  }
}

export async function writeCache(key: string, data: unknown): Promise<void> {
  try {
    await AsyncStorage.setItem(PREFIX + key, JSON.stringify({ at: Date.now(), data }, replacer));
  } catch {
    // Penyimpanan penuh/tidak tersedia: tetap jalan tanpa cache.
  }
}

export async function clearCache(): Promise<void> {
  try {
    const keys = (await AsyncStorage.getAllKeys()).filter((k) => k.startsWith(PREFIX));
    if (keys.length) await AsyncStorage.multiRemove(keys);
  } catch {
    // abaikan
  }
}
