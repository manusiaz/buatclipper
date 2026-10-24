// F-C11 native: notifikasi in-app (judul/isi/angka/ikon dari builder yang sama dengan web), tap = tandai dibaca + buka
// tujuan (layar native bila ada padanannya, selain itu browser). Offline: data cache terakhir + pita.
import { useFocusEffect, useRouter } from 'expo-router';
import { useCallback } from 'react';
import { Linking, Pressable, View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { buildNotificationViews, notificationIcon } from '@clipper/clipper-lib/notifications';
import { formatRelative } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { markRead, notifications, useLoad } from '@/data';
import { env } from '@/env';
import { useErrorText } from '@/i18n';
import { nativeRoute, webHref } from '@/links';
import { useTheme } from '@/theme';
import { Button, EmptyState, Icon, Row, Txt } from '@/ui/core';
import { OfflineBanner } from '@/ui/offline';
import { Screen } from '@/ui/screen';

export default function Notifications() {
  const t = useTranslations('notifications');
  const tc = useTranslations('common');
  const tn = useTranslations('clipper.notifications');
  const tm = useTranslations('clipper.mobile');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const { c, radius } = useTheme();
  const { claims } = useAuth();
  const uid = claims!.sub;
  const data = useLoad(() => notifications(uid), [uid], `notifications:${uid}`);
  useFocusEffect(useCallback(() => void data.reload(), [data.reload]));
  const items = buildNotificationViews(
    (data.data ?? []).map((r) => ({ id: r.id, event: r.event, payload: r.payload, read_at: r.read_at, created_at: r.created_at })),
    locale,
    (k, v) => t(k as never, v as never),
    (k) => tc(k as never),
    { brand: env.brandUrl, accounts: env.accountsUrl },
  );
  const unread = items.filter((n) => !n.read).length;
  const open = async (id: number, href: string | null) => {
    await markRead(uid, id);
    void data.reload();
    if (!href) return;
    const r = nativeRoute(href);
    if (r) router.push(r as never);
    else await Linking.openURL(webHref(href));
  };
  return (
    <Screen title={tn('title')} refreshing={data.loading && !!data.data} onRefresh={data.reload} banner={<OfflineBanner load={data} />}>
      {data.error && !data.data ? <EmptyState icon="error" title={err(data.error)} action={{ label: tm('refresh'), onPress: data.reload }} /> : null}
      {data.data && !items.length ? <EmptyState icon="notifications" title={tn('emptyTitle')} body={tn('emptyBody')} action={{ label: tn('toCampaigns'), onPress: () => router.navigate('/') }} /> : null}
      {items.length ? (
        <Row style={{ justifyContent: 'space-between' }}>
          <Txt variant="bodyS" tone="muted" accessibilityLiveRegion="polite">{unread ? tn('unread', { n: unread }) : tn('allRead')}</Txt>
          {unread ? <Button variant="link" size="sm" onPress={async () => (await markRead(uid), await data.reload())}>{tn('markAll')}</Button> : null}
        </Row>
      ) : null}
      {items.length ? (
        <View style={{ backgroundColor: c.surface, borderRadius: radius.card, borderWidth: 1, borderColor: c.border, overflow: 'hidden' }}>
          {items.map((n, i) => (
            <Pressable
              key={n.id}
              accessibilityRole="button"
              accessibilityLabel={[n.read ? null : tn('new'), n.title, n.body, n.facts].filter(Boolean).join('. ')}
              onPress={() => open(n.id, n.href)}
              android_ripple={{ color: c.border }}
              style={({ pressed }) => ({ flexDirection: 'row', gap: 12, padding: 14, borderTopWidth: i ? 1 : 0, borderColor: c.border, backgroundColor: pressed ? c.subtle : n.read ? c.surface : c.primarySoft })}
            >
              <View style={{ width: 40, height: 40, borderRadius: 20, alignItems: 'center', justifyContent: 'center', backgroundColor: n.read ? c.subtle : c.surface }}>
                <Icon name={notificationIcon(n.event)} size={20} color={n.read ? c.muted : c.primary} />
              </View>
              <View style={{ flex: 1, gap: 2 }}>
                <Txt variant="bodyS" weight={n.read ? '500' : '700'}>{n.title}</Txt>
                {n.body ? <Txt variant="caption" tone="text2" numberOfLines={3}>{n.body}</Txt> : null}
                {n.facts ? <Txt variant="caption" weight="600">{n.facts}</Txt> : null}
                {n.reason ? <Txt variant="caption" tone="muted" numberOfLines={2}>{n.reason}</Txt> : null}
                <Txt variant="caption" tone="muted">{formatRelative(n.createdAt, Date.now(), locale)}</Txt>
              </View>
              {!n.read ? <View style={{ width: 10, height: 10, borderRadius: 5, backgroundColor: c.primary, marginTop: 6 }} /> : n.href ? <Icon name="chevron_right" size={20} color={c.muted} /> : null}
            </Pressable>
          ))}
        </View>
      ) : null}
    </Screen>
  );
}
