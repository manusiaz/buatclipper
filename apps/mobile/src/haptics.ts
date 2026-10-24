// Haptic per momen DS Motion 25 (Android HapticFeedbackConstants) & 26 (iOS UIKit): hanya momen yang berarti,
// bukan tiap tap ("Haptic tiap tap — jadi berisik"). Web: tidak ada.
import * as H from 'expo-haptics';
import { Platform } from 'react-native';

const run = (android: H.AndroidHaptics, ios: () => Promise<void>) => {
  const p = Platform.OS === 'android' ? H.performAndroidHapticsAsync(android) : Platform.OS === 'ios' ? ios() : null;
  void p?.catch(() => {});
};

export const haptic = {
  /** Clip terkirim, claim berhasil, saldo cair (CONFIRM / .success). */
  success: () => run(H.AndroidHaptics.Confirm, () => H.notificationAsync(H.NotificationFeedbackType.Success)),
  /** Link tidak valid, aksi ditolak (REJECT / .error). */
  error: () => run(H.AndroidHaptics.Reject, () => H.notificationAsync(H.NotificationFeedbackType.Error)),
  /** Ganti filter / chip / segmented (iOS .selection; Android tanpa haptic khusus → ripple saja). */
  selection: () => (Platform.OS === 'ios' ? void H.selectionAsync().catch(() => {}) : undefined),
  /** Switch nyala/mati (TOGGLE_ON/OFF / .selection). */
  toggle: (on: boolean) => run(on ? H.AndroidHaptics.Toggle_On : H.AndroidHaptics.Toggle_Off, () => H.selectionAsync()),
  /** Menu tekan lama muncul (LONG_PRESS / .rigid). */
  longPress: () => run(H.AndroidHaptics.Long_Press, () => H.impactAsync(H.ImpactFeedbackStyle.Rigid)),
  /** Tahan tarik dana: progress penuh (GESTURE_END / .heavy). */
  threshold: () => run(H.AndroidHaptics.Gesture_End, () => H.impactAsync(H.ImpactFeedbackStyle.Heavy)),
};
