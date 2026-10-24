'use client';

// C3.2: push per perangkat. Izin browser → pushManager.subscribe (VAPID publik) → identity save_push_subscription.
// iPhone: push hanya untuk PWA yang sudah dipasang ke layar utama.
import { useEffect, useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Badge, Button } from '@clipper/ui';
import { base64UrlToBytes } from '@clipper/clipper-lib/pure';
import { deletePush, savePush } from './actions';

type State = 'loading' | 'unsupported' | 'ios-install' | 'denied' | 'off' | 'on';

const VAPID = process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY ?? '';

export function PushCard({ devices }: { devices: number }) {
  const t = useTranslations('clipper.settings.push');
  const [state, setState] = useState<State>('loading');
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  useEffect(() => {
    const ios = /iphone|ipad|ipod/i.test(navigator.userAgent);
    const standalone =
      window.matchMedia('(display-mode: standalone)').matches || (navigator as Navigator & { standalone?: boolean }).standalone;
    if (!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window) || !VAPID) {
      setState(ios && !standalone ? 'ios-install' : 'unsupported');
      return;
    }
    if (Notification.permission === 'denied') {
      setState('denied');
      return;
    }
    navigator.serviceWorker.ready
      .then((reg) => reg.pushManager.getSubscription())
      .then((sub) => setState(sub ? 'on' : 'off'))
      .catch(() => setState('off'));
  }, []);

  const enable = () =>
    start(async () => {
      setError(null);
      try {
        const perm = await Notification.requestPermission();
        if (perm !== 'granted') {
          setState(perm === 'denied' ? 'denied' : 'off');
          return;
        }
        const reg = await navigator.serviceWorker.ready;
        const sub =
          (await reg.pushManager.getSubscription()) ??
          (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: base64UrlToBytes(VAPID) }));
        const json = sub.toJSON();
        const r = await savePush({ endpoint: sub.endpoint, p256dh: json.keys?.p256dh ?? '', auth: json.keys?.auth ?? '' });
        if (!r.ok) {
          await sub.unsubscribe().catch(() => {});
          setError(r.message);
          return;
        }
        setState('on');
      } catch {
        setError(t('failed'));
      }
    });

  const disable = () =>
    start(async () => {
      setError(null);
      try {
        const reg = await navigator.serviceWorker.ready;
        const sub = await reg.pushManager.getSubscription();
        if (sub) {
          const r = await deletePush(sub.endpoint);
          if (!r.ok) {
            setError(r.message);
            return;
          }
          await sub.unsubscribe();
        }
        setState('off');
      } catch {
        setError(t('failed'));
      }
    });

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-start gap-3">
        <div className="min-w-0 flex-1">
          <p className="text-body-s font-bold text-ink">{t('title')}</p>
          <p className="text-caption text-muted">{t('body')}</p>
        </div>
        {state === 'on' ? <Badge tone="success" dot>{t('active')}</Badge> : null}
      </div>
      {error ? <Alert tone="danger">{error}</Alert> : null}
      {state === 'unsupported' ? <Alert tone="info">{t('unsupported')}</Alert> : null}
      {state === 'ios-install' ? <Alert tone="info">{t('iosInstall')}</Alert> : null}
      {state === 'denied' ? <Alert tone="warn">{t('denied')}</Alert> : null}
      {state === 'off' || state === 'loading' ? (
        <Button iconLeft="notifications" loading={pending || state === 'loading'} onClick={enable} className="self-start">
          {t('enable')}
        </Button>
      ) : null}
      {state === 'on' ? (
        <Button variant="secondary" iconLeft="close" loading={pending} onClick={disable} className="self-start">
          {t('disable')}
        </Button>
      ) : null}
      {devices > 0 ? <p className="text-caption text-muted">{t('devices', { n: devices })}</p> : null}
    </div>
  );
}
