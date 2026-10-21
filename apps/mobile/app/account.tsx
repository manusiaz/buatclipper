// Menu avatar (§6.8) native: profil, notifikasi HP (push Expo), bahasa, tema, tautan web (profil & Trust Score,
// leaderboard, ajak teman, akun & KYC), keluar.
import { useEffect, useState } from 'react';
import { Image, View } from 'react-native';
import { useTranslations } from 'use-intl';
import { initials } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { chrome, useLoad } from '@/data';
import { usePrefs } from '@/prefs';
import { disablePush, enablePush, pushState, type PushState } from '@/push';
import { useTheme } from '@/theme';
import { Alert, Button, Card, Row, Txt } from '@/ui/core';
import { Chip } from '@/ui/chip';
import { Screen } from '@/ui/screen';
import { openWeb } from '@/web';

export default function Account() {
  const t = useTranslations('clipper');
  const tm = useTranslations('clipper.mobile');
  const { c } = useTheme();
  const { claims, signOut } = useAuth();
  const prefs = usePrefs();
  const info = useLoad(() => chrome(claims!.sub), [claims?.sub]);
  const [push, setPush] = useState<PushState | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    void pushState().then(setPush);
  }, []);
  const name = info.data?.profile?.display_name || info.data?.profile?.username || claims?.email || '';
  const togglePush = async () => {
    setBusy(true);
    setPush(push === 'on' ? await disablePush() : await enablePush());
    setBusy(false);
  };
  return (
    <Screen back title={tm('menu')}>
      <Card>
        <Row gap={12}>
          {info.data?.avatar ? (
            <Image source={{ uri: info.data.avatar }} style={{ width: 52, height: 52, borderRadius: 26 }} />
          ) : (
            <View style={{ width: 52, height: 52, borderRadius: 26, backgroundColor: c.primarySoft, alignItems: 'center', justifyContent: 'center' }}>
              <Txt variant="h6" style={{ color: c.primarySoftFg }}>{initials(name || '?')}</Txt>
            </View>
          )}
          <View style={{ flex: 1 }}>
            <Txt variant="h6" numberOfLines={1}>{name}</Txt>
            {info.data?.profile?.username ? <Txt variant="caption" tone="muted">@{info.data.profile.username}</Txt> : null}
          </View>
        </Row>
      </Card>

      <Card>
        <Txt variant="h6">{tm('pushTitle')}</Txt>
        {push === 'unavailable' ? <Txt variant="bodyS" tone="muted">{tm('pushUnavailable')}</Txt> : null}
        {push === 'denied' ? <Alert tone="warn">{tm('pushDenied')}</Alert> : null}
        {push === 'on' || push === 'off' ? (
          <Button variant={push === 'on' ? 'secondary' : 'primary'} icon="notifications" loading={busy} onPress={togglePush}>
            {push === 'on' ? tm('pushOn') : tm('pushOff')}
          </Button>
        ) : null}
      </Card>

      <Card>
        <Txt variant="h6">{tm('language')}</Txt>
        <Row>
          <Chip label="Indonesia" active={prefs.locale === 'id'} onPress={() => prefs.setLocale('id')} />
          <Chip label="English" active={prefs.locale === 'en'} onPress={() => prefs.setLocale('en')} />
        </Row>
        <Txt variant="h6">{tm('theme')}</Txt>
        <Row>
          <Chip label={tm('themeSystem')} active={prefs.theme === 'system'} onPress={() => prefs.setTheme('system')} />
          <Chip label={tm('themeLight')} active={prefs.theme === 'light'} onPress={() => prefs.setTheme('light')} />
          <Chip label={tm('themeDark')} active={prefs.theme === 'dark'} onPress={() => prefs.setTheme('dark')} />
        </Row>
      </Card>

      <Card>
        <Txt variant="caption" tone="muted">{tm('openWeb')}</Txt>
        <Button variant="link" icon="person" onPress={() => openWeb('app', '/profile')}>{t('menu.profile')}</Button>
        <Button variant="link" icon="leaderboard" onPress={() => openWeb('app', '/leaderboard')}>{t('menu.leaderboard')}</Button>
        <Button variant="link" icon="group_add" onPress={() => openWeb('app', '/referral')}>{t('menu.referral')}</Button>
        <Button variant="link" icon="id_card" onPress={() => openWeb('accounts', '/')}>{t('menu.account')}</Button>
      </Card>

      <Button full variant="secondary" icon="logout" onPress={signOut}>{t('menu.signOut')}</Button>
    </Screen>
  );
}
