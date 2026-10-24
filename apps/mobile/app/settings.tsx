// Pengaturan (C2.5): bahasa & tema (perangkat ini), notifikasi HP (push Expo, per perangkat), email promosi
// (api notification_prefs; email transaksional selalu dikirim), tautan Akun & KYC.
import { useEffect, useState } from 'react';
import { Switch, View } from 'react-native';
import { useTranslations } from 'use-intl';
import { useAuth } from '@/auth';
import { notificationSettings, setEmailPromotions, useLoad } from '@/data';
import { haptic } from '@/haptics';
import { usePrefs } from '@/prefs';
import { disablePush, enablePush, pushState, type PushState } from '@/push';
import { useTheme } from '@/theme';
import { Alert, Row, Txt } from '@/ui/core';
import { Chip } from '@/ui/chip';
import { ListRow, ListSection } from '@/ui/list';
import { Screen } from '@/ui/screen';
import { useToast } from '@/ui/toast';
import { openWeb } from '@/web';

export default function Settings() {
  const t = useTranslations('clipper.settings');
  const tm = useTranslations('clipper.mobile');
  const tc = useTranslations('common');
  const { c } = useTheme();
  const toast = useToast();
  const { claims } = useAuth();
  const uid = claims!.sub;
  const prefs = usePrefs();
  const data = useLoad(() => notificationSettings(uid), [uid]);
  const [promo, setPromo] = useState<boolean | null>(null);
  const [push, setPush] = useState<PushState | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    void pushState().then(setPush);
  }, []);
  useEffect(() => {
    if (data.data) setPromo(data.data.promotions);
  }, [data.data]);
  const togglePush = async (on: boolean) => {
    haptic.toggle(on);
    setBusy(true);
    const next = on ? await enablePush() : await disablePush();
    setBusy(false);
    setPush(next);
    if ((on && next !== 'on') || (!on && next !== 'off')) toast({ tone: 'danger', title: t('push.failed') });
    void data.reload();
  };
  const togglePromo = async (on: boolean) => {
    haptic.toggle(on);
    setPromo(on);
    if (!(await setEmailPromotions(uid, on))) {
      setPromo(!on);
      return toast({ tone: 'danger', title: tm('saveFailed') });
    }
    toast({ title: on ? t('promoOn') : t('promoOff') });
  };
  const sw = (value: boolean, onChange: (v: boolean) => void, disabled?: boolean, label?: string) => (
    <Switch value={value} onValueChange={onChange} disabled={disabled} accessibilityLabel={label} trackColor={{ true: c.primary, false: c.borderStrong }} thumbColor="#ffffff" ios_backgroundColor={c.borderStrong} />
  );
  return (
    <Screen title={t('title')}>
      <ListSection title={t('display')}>
        <ListRow first icon="language" label={t('language')} right={<Row gap={6}><Chip label="ID" active={prefs.locale === 'id'} onPress={() => prefs.setLocale('id')} /><Chip label="EN" active={prefs.locale === 'en'} onPress={() => prefs.setLocale('en')} /></Row>} />
        <View style={{ borderTopWidth: 1, borderColor: c.border, padding: 14, gap: 8 }}>
          <Txt variant="bodyS" weight="600">{t('theme')}</Txt>
          <Row gap={8}>
            <Chip label={tc('themeSystem')} active={prefs.theme === 'system'} onPress={() => prefs.setTheme('system')} />
            <Chip label={tc('themeLight')} active={prefs.theme === 'light'} onPress={() => prefs.setTheme('light')} />
            <Chip label={tc('themeDark')} active={prefs.theme === 'dark'} onPress={() => prefs.setTheme('dark')} />
          </Row>
        </View>
      </ListSection>

      <ListSection title={t('notifications')} footer={t('notificationsBody')}>
        <ListRow
          first
          icon="notifications"
          label={tm('pushTitle')}
          detail={push === 'on' ? tm('pushOn') : push === 'unavailable' ? tm('pushUnavailable') : push === 'denied' ? tm('pushDenied') : t('push.body')}
          right={push === 'on' || push === 'off' ? sw(push === 'on', togglePush, busy, tm('pushTitle')) : undefined}
        />
        <ListRow icon="mail" label={t('promo')} detail={t('promoBody')} right={promo === null ? undefined : sw(promo, togglePromo, false, t('promo'))} />
      </ListSection>
      {data.data?.devices ? <Txt variant="caption" tone="muted">{t('push.devices', { n: data.data.devices })}</Txt> : null}
      {push === 'denied' ? <Alert tone="warn">{tm('pushDenied')}</Alert> : null}

      <ListSection title={t('account')} footer={t('accountBody')}>
        <ListRow first icon="id_card" label={t('accountAction')} external onPress={() => void openWeb('accounts', '/')} />
      </ListSection>
    </Screen>
  );
}
