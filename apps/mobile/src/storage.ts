// Sesi Supabase identity di Keychain (iOS) / Keystore (Android) lewat SecureStore. Nilai dipecah per 1.800 karakter
// (SecureStore iOS menolak nilai > 2.048 byte; sesi + JWT ber-claim lebih besar). Web (uji Expo web): localStorage.
import * as SecureStore from 'expo-secure-store';
import { Platform } from 'react-native';

const CHUNK = 1800;
const safeKey = (k: string) => k.replace(/[^A-Za-z0-9._-]/g, '_');

export function chunks(value: string, size = CHUNK): string[] {
  const out: string[] = [];
  for (let i = 0; i < value.length; i += size) out.push(value.slice(i, i + size));
  return out.length ? out : [''];
}

async function remove(key: string) {
  const n = Number(await SecureStore.getItemAsync(`${key}.n`)) || 0;
  await Promise.all([...Array(n).keys()].map((i) => SecureStore.deleteItemAsync(`${key}.${i}`)));
  await SecureStore.deleteItemAsync(`${key}.n`);
}

export const secureStorage = {
  async getItem(raw: string): Promise<string | null> {
    if (Platform.OS === 'web') return globalThis.localStorage?.getItem(raw) ?? null;
    const key = safeKey(raw);
    const n = Number(await SecureStore.getItemAsync(`${key}.n`)) || 0;
    if (!n) return null;
    const parts = await Promise.all([...Array(n).keys()].map((i) => SecureStore.getItemAsync(`${key}.${i}`)));
    return parts.some((p) => p == null) ? null : parts.join('');
  },
  async setItem(raw: string, value: string): Promise<void> {
    if (Platform.OS === 'web') return void globalThis.localStorage?.setItem(raw, value);
    const key = safeKey(raw);
    await remove(key);
    const parts = chunks(value);
    await Promise.all(parts.map((p, i) => SecureStore.setItemAsync(`${key}.${i}`, p)));
    await SecureStore.setItemAsync(`${key}.n`, String(parts.length));
  },
  async removeItem(raw: string): Promise<void> {
    if (Platform.OS === 'web') return void globalThis.localStorage?.removeItem(raw);
    await remove(safeKey(raw));
  },
};
