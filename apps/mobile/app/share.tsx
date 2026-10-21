// Share sheet native (DS Android/iOS 01): link dari app sosmed → pilih claim terbuka → Submit dengan link terisi.
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useLocale, useTranslations } from 'use-intl';
import { sharedUrl } from '@clipper/clipper-lib/pure';
import { formatRelative } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { openClaims, useLoad } from '@/data';
import { useTheme } from '@/theme';
import { Button, Card, EmptyState, Row, Txt } from '@/ui/core';
import { Screen } from '@/ui/screen';

export default function Share() {
  const params = useLocalSearchParams<{ url?: string; text?: string }>();
  const t = useTranslations('clipper');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const router = useRouter();
  const { c, radius } = useTheme();
  const { claims } = useAuth();
  const url = sharedUrl({ url: params.url, text: params.text });
  const data = useLoad(() => openClaims(claims!.sub), [claims?.sub]);
  return (
    <Screen back title={t('share.title')}>
      {!url ? (
        <EmptyState icon="link_off" title={t('share.badTitle')} body={t('share.badBody')} action={{ label: t('share.browse'), onPress: () => router.replace('/') }} />
      ) : data.data && !data.data.length ? (
        <EmptyState icon="campaign" title={t('share.emptyTitle')} body={t('share.emptyBody')} action={{ label: t('share.browse'), onPress: () => router.replace('/') }} />
      ) : (
        <>
          <Txt variant="bodyS" tone="text2">{t('share.body')}</Txt>
          <Txt variant="caption" tone="muted" numberOfLines={1} style={{ backgroundColor: c.surface2, borderRadius: radius.control, padding: 10 }}>{url}</Txt>
          {(data.data ?? []).map((cl) => (
            <Card key={cl.id} padding={14}>
              <Txt variant="label" weight="700" numberOfLines={2}>{cl.title || t('tasks.campaign')}</Txt>
              <Row style={{ justifyContent: 'space-between' }}>
                <Txt variant="caption" tone="muted">{`${t('claim.expiresIn')} ${formatRelative(cl.expiresAt, Date.now(), locale)}`}</Txt>
                <Button size="sm" variant="ink" icon="upload" onPress={() => router.push({ pathname: '/submit', params: { campaignId: cl.campaignId, claimId: cl.id, url } })}>
                  {t('share.pick')}
                </Button>
              </Row>
            </Card>
          ))}
        </>
      )}
    </Screen>
  );
}
