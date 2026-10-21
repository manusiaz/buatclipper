// F-C03 / C1.4 native: daftar campaign + CTA 6 state per user, cari, filter platform, muat lagi (cursor).
import { useRouter } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ScrollView } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { enabledPlatforms, fixKey } from '@clipper/clipper-lib/pure';
import type { CampaignFilters } from '@clipper/clipper-lib/filters';
import { platformLabels, type Platform } from '@clipper/ui/platform-paths';
import { useAuth } from '@/auth';
import { campaignPage, settings, useLoad, verifiedAccounts, type CardData } from '@/data';
import { useErrorText } from '@/i18n';
import { CampaignCardView } from '@/ui/campaign-card';
import { Alert, Button, EmptyState, Field, Txt } from '@/ui/core';
import { Chip } from '@/ui/chip';
import { Screen } from '@/ui/screen';
import { openWeb } from '@/web';

export default function Campaigns() {
  const t = useTranslations('clipper.campaigns');
  const tc = useTranslations('clipper');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const { claims } = useAuth();
  const uid = claims!.sub;
  const [q, setQ] = useState('');
  const [query, setQuery] = useState('');
  const [platform, setPlatform] = useState('');
  const filters: CampaignFilters = { q: query, platform, category: '', status: 'active', sort: 'newest' };
  const page = useLoad(() => campaignPage(uid, filters, null, locale), [uid, query, platform, locale]);
  const meta = useLoad(async () => ({ verified: await verifiedAccounts(uid), platforms: enabledPlatforms((await settings(['public.flags.platforms']))['public.flags.platforms']) as Platform[] }), [uid]);
  const [more, setMore] = useState<CardData[]>([]);
  const [next, setNext] = useState<string | null>(null);
  const [loadingMore, setLoadingMore] = useState(false);
  useEffect(() => {
    setMore([]);
    setNext(page.data?.next ?? null);
  }, [page.data]);
  const loadMore = useCallback(async () => {
    if (!next) return;
    setLoadingMore(true);
    const r = await campaignPage(uid, filters, next, locale).catch(() => null);
    setLoadingMore(false);
    if (r) {
      setMore((m) => [...m, ...r.items]);
      setNext(r.next);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [next, uid, query, platform, locale]);

  const items = [...(page.data?.items ?? []), ...more];
  const open = (c: CardData) => router.push({ pathname: '/campaign/[id]', params: c.ctaState === 'claimed_not_submitted' ? { id: c.id, submit: '1' } : { id: c.id } });
  const reload = () => Promise.all([page.reload(), meta.reload()]);

  return (
    <Screen tabbed refreshing={page.loading && !!page.data} onRefresh={reload}>
      <Txt variant="h4" accessibilityRole="header">{t('title')}</Txt>
      {meta.data && !meta.data.verified ? (
        <Alert tone="warn" title={t('connectTitle')} action={{ label: t('connectAction'), onPress: () => router.push('/social') }}>
          {t('connectBody')}
        </Alert>
      ) : null}
      <Field label={t('search')} placeholder={t('searchPlaceholder')} value={q} onChangeText={setQ} returnKeyType="search" onSubmitEditing={() => setQuery(q.trim().slice(0, 80))} />
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
        <Chip label={t('allPlatforms')} active={!platform} onPress={() => setPlatform('')} />
        {(meta.data?.platforms ?? []).map((p) => (
          <Chip key={p} label={platformLabels[p]} platform={p} active={platform === p} onPress={() => setPlatform(p)} />
        ))}
      </ScrollView>
      {page.error && !page.data ? (
        <EmptyState icon="wifi_off" title={t('loadError')} body={err(page.error)} action={{ label: t('retry'), onPress: page.reload }} />
      ) : page.data && !items.length ? (
        query || platform ? (
          <EmptyState icon="search" title={t('emptyFilteredTitle')} body={t('emptyFilteredBody')} action={{ label: t('reset'), onPress: () => (setQ(''), setQuery(''), setPlatform('')) }} />
        ) : (
          <EmptyState icon="campaign" title={t('emptyTitle')} body={t('emptyBody')} action={{ label: t('emptyAction'), onPress: () => router.push('/social') }} />
        )
      ) : (
        items.map((c) => {
          const fix = c.ctaState === 'not_eligible' ? fixKey(c.ctaReason) : null;
          return (
            <CampaignCardView
              key={c.id}
              card={c}
              locale={locale}
              onOpen={() => open(c)}
              reasonText={c.ctaState === 'not_eligible' && c.ctaReason ? err(`not_eligible:${c.ctaReason}`) : null}
              onCta={
                fix === 'connect'
                  ? () => router.push('/social')
                  : fix === 'kyc'
                    ? () => openWeb('accounts', '/kyc')
                    : fix === 'onboarding'
                      ? () => openWeb('accounts', '/onboarding')
                      : undefined
              }
            />
          );
        })
      )}
      {next ? (
        <Button full variant="secondary" loading={loadingMore} onPress={loadMore}>
          {tc('campaigns.loadMore')}
        </Button>
      ) : null}
    </Screen>
  );
}
