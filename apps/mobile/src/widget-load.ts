// Snapshot widget dari sesi app: dipakai handler headless Android dan refresh iOS. Gagal jaringan → snapshot terakhir
// yang tersimpan (widget tetap menampilkan angka, bukan kosong).
import AsyncStorage from '@react-native-async-storage/async-storage';
import { decodeClaims, isAdmin } from './claims';
import { widgetData } from './data';
import { identity } from './supabase';
import { buildWidgetSnapshot, type WidgetSnapshot } from './widget-snapshot';

const LAST = 'clipper.widget.last';

export async function loadWidgetSnapshot(): Promise<WidgetSnapshot> {
  const locale = (await AsyncStorage.getItem('clipper.locale')) === 'en' ? 'en' : 'id';
  const { data } = await identity.auth.getSession();
  const claims = data.session ? decodeClaims(data.session.access_token) : null;
  const empty = { signedIn: false, available: 0, pending: 0, payout: null, review: 0, campaigns: [] };
  if (!claims || isAdmin(claims)) {
    await AsyncStorage.removeItem(LAST);
    return buildWidgetSnapshot(empty, locale);
  }
  try {
    const snap = buildWidgetSnapshot(await widgetData(claims.sub, locale), locale);
    await AsyncStorage.setItem(LAST, JSON.stringify(snap));
    return snap;
  } catch {
    const last = await AsyncStorage.getItem(LAST);
    return last ? (JSON.parse(last) as WidgetSnapshot) : buildWidgetSnapshot(empty, locale);
  }
}
