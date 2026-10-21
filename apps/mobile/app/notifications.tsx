// F-C11 native: notifikasi in-app (judul/isi dari builder yang sama dengan web), tap = tandai dibaca + buka tujuan.
import { useRouter } from 'expo-router';
import { Linking, Pressable, View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { buildNotificationViews } from '@clipper/clipper-lib/notifications';
import { formatRelative } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { markRead, notifications, useLoad } from '@/data';
import { env } from '@/env';
import { nativeRoute } from '@/links';
import { useTheme } from '@/theme';
import { Button, Card, EmptyState, Row, Txt } from '@/ui/core';
import { Screen } from '@/ui/screen';

export default function Notifications() {
  const t = useTranslations('notifications');
  const tc = useTranslations('common');
  const tn = useTranslations('clipper.notifications');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const router = useRouter();
  const { c } = useTheme();
  const { claims } = useAuth();
  const uid = claims!.sub;
  const data = useLoad(() => notifications(uid), [uid]);
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
    await data.reload();
    if (!href) return;
    const r = nativeRoute(href);
    if (r) router.push(r as never);
    else await Linking.openURL(href);
  };
  return (
    <Screen back title={tn('title')} refreshing={data.loading && !!data.data} onRefresh={data.reload}>
      {data.data && !items.length ? <EmptyState icon="notifications" title={tn('emptyTitle')} body={tn('emptyBody')} action={{ label: tn('toCampaigns'), onPress: () => router.push('/') }} /> : null}
      {items.length ? (
        <Row style={{ justifyContent: 'space-between' }}>
          <Txt variant="bodyS" tone="muted">{unread ? tn('unread', { n: unread }) : tn('allRead')}</Txt>
          {unread ? <Button variant="link" size="sm" onPress={async () => (await markRead(uid), await data.reload())}>{tn('markAll')}</Button> : null}
        </Row>
      ) : null}
      {items.map((n) => (
        <Pressable key={n.id} accessibilityRole="button" onPress={() => open(n.id, n.href)}>
          <Card padding={14} style={{ borderLeftWidth: n.read ? 0 : 3, borderLeftColor: c.primary }}>
            <Row style={{ justifyContent: 'space-between', flexWrap: 'nowrap' }}>
              <Txt variant="label" weight="700" style={{ flex: 1 }}>{n.title}</Txt>
              <Txt variant="caption" tone="muted">{formatRelative(n.createdAt, Date.now(), locale)}</Txt>
            </Row>
            <Txt variant="bodyS" tone="text2">{n.body}</Txt>
            {n.reason ? <Txt variant="caption" tone="muted">{n.reason}</Txt> : null}
            {!n.read ? <View style={{ alignSelf: 'flex-start' }}><Txt variant="caption" weight="700" tone="primary">{tn('new')}</Txt></View> : null}
          </Card>
        </Pressable>
      ))}
    </Screen>
  );
}
