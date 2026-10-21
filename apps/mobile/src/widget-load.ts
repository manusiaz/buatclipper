// Snapshot widget dari sesi app: dipakai handler headless Android dan refresh iOS. Gagal jaringan → snapshot terakhir
// milik user yang sama (widget tetap menampilkan angka, bukan kosong). Keluar / ganti akun di tengah muatan: hasilnya
// dibuang (generasi + cek ulang sesi), jadi saldo akun lama tidak kembali ke layar utama.
import AsyncStorage from '@react-native-async-storage/async-storage';
import { decodeClaims, isAdmin } from './claims';
import { widgetData } from './data';
import { identity } from './supabase';
import { buildWidgetSnapshot, type WidgetSnapshot } from './widget-snapshot';

const LAST = 'clipper.widget.last';
let generation = 0;

/** Dipanggil saat keluar: muatan widget yang sedang berjalan tidak boleh menulis/merender data akun ini lagi. */
export const invalidateWidgetSnapshot = () => void generation++;

const uidOf = async () => {
  const { data } = await identity.auth.getSession();
  const claims = data.session ? decodeClaims(data.session.access_token) : null;
  return claims && !isAdmin(claims) ? claims.sub : null;
};

export async function loadWidgetSnapshot(): Promise<WidgetSnapshot> {
  const gen = generation;
  const locale = (await AsyncStorage.getItem('clipper.locale')) === 'en' ? 'en' : 'id';
  const uid = await uidOf();
  const empty = buildWidgetSnapshot({ signedIn: false, available: 0, pending: 0, payout: null, review: 0, campaigns: [] }, locale);
  if (!uid) {
    await AsyncStorage.removeItem(LAST);
    return empty;
  }
  try {
    const input = await widgetData(uid, locale);
    if (gen !== generation || (await uidOf()) !== uid) return empty;
    const snap = buildWidgetSnapshot(input, locale);
    await AsyncStorage.setItem(LAST, JSON.stringify({ uid, snap }));
    return snap;
  } catch {
    const last = JSON.parse((await AsyncStorage.getItem(LAST)) ?? 'null') as { uid?: string; snap?: WidgetSnapshot } | null;
    return gen === generation && last?.uid === uid && last.snap ? last.snap : empty;
  }
}
