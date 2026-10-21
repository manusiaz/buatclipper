// Saat login: daftarkan kategori tombol notifikasi + arahkan tap notifikasi (juga saat app dibuka dari notifikasi).
import { useRouter } from 'expo-router';
import { useEffect } from 'react';
import { Linking } from 'react-native';
import { useTranslations } from 'use-intl';
import { nativeRoute } from './links';
import { Notifications, setupCategories, targetOf } from './push';

export function PushGate() {
  const router = useRouter();
  const t = useTranslations('clipper.mobile');
  useEffect(() => {
    void setupCategories({ wallet: t('actionWallet'), clipAgain: t('actionClipAgain') });
    const go = (url: string | null) => {
      if (!url) return;
      const r = nativeRoute(url);
      if (r) router.push(r as never);
      else void Linking.openURL(url);
    };
    void Notifications.getLastNotificationResponseAsync().then((r) => r && go(targetOf(r)));
    const sub = Notifications.addNotificationResponseReceivedListener((r) => go(targetOf(r)));
    return () => sub.remove();
  }, [router, t]);
  return null;
}
