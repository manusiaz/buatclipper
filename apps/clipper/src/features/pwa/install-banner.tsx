'use client';

// C3.1 banner Pasang di layar utama: Android = prompt browser (beforeinstallprompt), iPhone = panduan Share → Add to Home
// Screen. Tutup = disimpan di localStorage perangkat ini.
import { useEffect, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import { Alert } from '@clipper/ui';

interface InstallPromptEvent extends Event {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>;
}

const KEY = 'clipper-install-dismissed';

function dismissed(): boolean {
  try {
    return localStorage.getItem(KEY) === '1';
  } catch {
    return false;
  }
}

export function InstallBanner() {
  const t = useTranslations('clipper.pwa');
  const [mode, setMode] = useState<'android' | 'ios' | null>(null);
  const deferred = useRef<InstallPromptEvent | null>(null);

  useEffect(() => {
    const standalone =
      window.matchMedia('(display-mode: standalone)').matches || (navigator as Navigator & { standalone?: boolean }).standalone;
    if (standalone || dismissed()) return;
    const onPrompt = (e: Event) => {
      e.preventDefault();
      deferred.current = e as InstallPromptEvent;
      setMode('android');
    };
    const onInstalled = () => setMode(null);
    window.addEventListener('beforeinstallprompt', onPrompt);
    window.addEventListener('appinstalled', onInstalled);
    if (/iphone|ipad|ipod/i.test(navigator.userAgent)) setMode('ios');
    return () => {
      window.removeEventListener('beforeinstallprompt', onPrompt);
      window.removeEventListener('appinstalled', onInstalled);
    };
  }, []);

  if (!mode) return null;

  const close = () => {
    try {
      localStorage.setItem(KEY, '1');
    } catch {
      // mode privat: cukup sembunyikan untuk sesi ini
    }
    setMode(null);
  };

  return (
    <Alert
      tone="info"
      icon="install_mobile"
      title={t('title')}
      onDismiss={close}
      dismissLabel={t('dismiss')}
      action={
        mode === 'android'
          ? {
              label: t('install'),
              onClick: async () => {
                const e = deferred.current;
                if (!e) return;
                await e.prompt();
                const { outcome } = await e.userChoice;
                if (outcome === 'accepted') setMode(null);
              },
            }
          : undefined
      }
    >
      {mode === 'android' ? t('androidBody') : t('iosBody')}
    </Alert>
  );
}
