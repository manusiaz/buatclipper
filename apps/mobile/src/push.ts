// Push app native: token Expo perangkat ini → identity api.save_expo_push_token (E-36, kind expo); dikirim bridge
// send_push lewat Expo Push API. Kategori tombol = aksi template (submission.approved → Lihat saldo / Kirim clip lagi).
import Constants from 'expo-constants';
import * as Device from 'expo-device';
import * as Notifications from 'expo-notifications';
import { Platform } from 'react-native';
import { identityApi } from './supabase';

export type PushState = 'on' | 'off' | 'denied' | 'unavailable';

Notifications.setNotificationHandler({
  handleNotification: async () => ({ shouldPlaySound: true, shouldSetBadge: true, shouldShowBanner: true, shouldShowList: true }),
});

const projectId = () => (Constants.expoConfig?.extra?.eas as { projectId?: string } | undefined)?.projectId;

export async function setupCategories(labels: { wallet: string; clipAgain: string }) {
  await Notifications.setNotificationCategoryAsync('submission_approved', [
    { identifier: 'wallet', buttonTitle: labels.wallet, options: { opensAppToForeground: true } },
    { identifier: 'campaign', buttonTitle: labels.clipAgain, options: { opensAppToForeground: true } },
  ]);
}

async function token(): Promise<string | null> {
  if (!Device.isDevice || !projectId()) return null;
  return (await Notifications.getExpoPushTokenAsync({ projectId: projectId() })).data;
}

export async function pushState(): Promise<PushState> {
  if (!Device.isDevice || !projectId()) return 'unavailable';
  const { status } = await Notifications.getPermissionsAsync();
  if (status === 'denied') return 'denied';
  if (status !== 'granted') return 'off';
  const t = await token();
  if (!t) return 'unavailable';
  const { data } = await identityApi.from('push_subscriptions').select('id').eq('endpoint', t).maybeSingle();
  return data ? 'on' : 'off';
}

export async function enablePush(): Promise<PushState> {
  if (!Device.isDevice || !projectId()) return 'unavailable';
  if (Platform.OS === 'android') {
    await Notifications.setNotificationChannelAsync('default', { name: 'Clipper', importance: Notifications.AndroidImportance.HIGH });
  }
  const { status } = await Notifications.requestPermissionsAsync();
  if (status !== 'granted') return 'denied';
  const t = await token();
  if (!t) return 'unavailable';
  const { error } = await identityApi.rpc('save_expo_push_token', { p_token: t });
  return error ? 'off' : 'on';
}

export async function disablePush(): Promise<PushState> {
  const t = await token();
  if (!t) return 'off';
  const { error } = await identityApi.from('push_subscriptions').delete().eq('endpoint', t);
  return error ? 'on' : 'off';
}

/** Saat keluar: hapus langganan selagi masih login, lalu cabut registrasi push perangkat (padanan unsubscribe web) —
 * walau DELETE gagal (offline), token lama ditolak FCM/APNs sehingga bridge menghapus barisnya di kiriman berikutnya. */
export async function releasePush(): Promise<void> {
  if (!Device.isDevice || !projectId()) return;
  await disablePush().catch(() => 'on');
  await Notifications.unregisterForNotificationsAsync().catch(() => {});
}

/** Tujuan tap notifikasi: tombol aksi (data.actions[id]) atau url utama. */
export function targetOf(response: Notifications.NotificationResponse): string | null {
  const data = response.notification.request.content.data as { url?: unknown; actions?: Record<string, unknown> } | undefined;
  const byAction = data?.actions?.[response.actionIdentifier];
  const url = typeof byAction === 'string' ? byAction : data?.url;
  return typeof url === 'string' && /^https:\/\//.test(url) ? url : null;
}

export { Notifications };
