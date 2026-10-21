// Tab Campaign (F-C03 / C1.4): banner beranda, cari (debounce 350 ms), filter di sheet (platform, kategori, status,
// urutan), kartu dengan CTA 6 state per user, muat otomatis dekat ujung daftar (cursor, tanpa duplikat).
// ≥ 840 dp (DS Android "Expanded"): daftar + detail berdampingan.
import { useRouter } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import { ActionSheetIOS, Image, Linking, Platform as RN, Pressable, ScrollView, Share, useWindowDimensions, View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { enabledPlatforms, fixKey } from '@clipper/clipper-lib/pure';
import { isFiltered } from '@clipper/clipper-lib/filters';
import { parseHomeBanners } from '@clipper/ui/banners';
import { platformLabels, type Platform } from '@clipper/ui/platform-paths';
import { useAuth } from '@/auth';
import { campaignPage, settings, useLoad, verifiedAccounts, type CardData } from '@/data';
import { env } from '@/env';
import { DEFAULT_FILTERS, setFilters, useFilters } from '@/filters-store';
import { runFix } from '@/fix';
import { haptic } from '@/haptics';
import { useErrorText } from '@/i18n';
import { nativeRoute } from '@/links';
import { CampaignDetail } from '@/screens/campaign-detail';
import { useTheme } from '@/theme';
import { CampaignCardView } from '@/ui/campaign-card';
import { Alert, Button, EmptyState, Field, Icon, Row, Txt } from '@/ui/core';
import { Chip } from '@/ui/chip';
import { OfflineBanner } from '@/ui/offline';
import { Screen } from '@/ui/screen';

const LIST_DETAIL_MIN_WIDTH = 840;

export default function Campaigns() {
  const t = useTranslations('clipper.campaigns');
  const tc = useTranslations('clipper');
  const tm = useTranslations('clipper.mobile');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const { c, radius } = useTheme();
  const { claims } = useAuth();
  const uid = claims!.sub;
  const wide = useWindowDimensions().width >= LIST_DETAIL_MIN_WIDTH;
  const filters = useFilters();
  const [q, setQ] = useState(filters.q);
  useEffect(() => {
    const id = setTimeout(() => setFilters({ q: q.trim().slice(0, 80) }), 350);
    return () => clearTimeout(id);
  }, [q]);
  const key = `${filters.q}|${filters.platform}|${filters.category}|${filters.status}|${filters.sort}`;
  const page = useLoad(() => campaignPage(uid, filters, null, locale), [uid, key, locale], `campaigns:${uid}:${key}:${locale}`);
  const meta = useLoad(
    async () => {
      const s = await settings(['public.flags.platforms', 'public.home.banners']);
      return { verified: await verifiedAccounts(uid), platforms: enabledPlatforms(s['public.flags.platforms']) as Platform[], banners: parseHomeBanners(s['public.home.banners'], env.appUrl) };
    },
    [uid],
    `campaigns-meta:${uid}`,
  );
  const [more, setMore] = useState<CardData[]>([]);
  const [next, setNext] = useState<string | null>(null);
  const [loadingMore, setLoadingMore] = useState(false);
  const [moreError, setMoreError] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const busy = useRef(false);
  useEffect(() => {
    setMore([]);
    setMoreError(null);
    setNext(page.data?.next ?? null);
  }, [page.data]);
  const loadMore = useCallback(async () => {
    if (!next || busy.current) return;
    busy.current = true;
    setLoadingMore(true);
    setMoreError(null);
    try {
      const r = await campaignPage(uid, filters, next, locale);
      setMore((m) => {
        const seen = new Set([...(page.data?.items ?? []), ...m].map((x) => x.id));
        return [...m, ...r.items.filter((x) => !seen.has(x.id))];
      });
      setNext(r.next);
    } catch (e) {
      setMoreError(e instanceof Error ? e.message : String(e));
    } finally {
      busy.current = false;
      setLoadingMore(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [next, uid, key, locale, page.data]);

  const items = [...(page.data?.items ?? []), ...more];
  const open = (card: CardData) => {
    if (wide) return setSelected(card.id);
    router.push({ pathname: '/campaign/[id]', params: card.ctaState === 'claimed_not_submitted' ? { id: card.id, submit: '1' } : { id: card.id } });
  };
  const menu = (card: CardData) => {
    if (RN.OS !== 'ios') return;
    haptic.longPress();
    const share = () => Share.share({ message: `${card.title} — ${env.appUrl}/campaigns/${card.id}`, url: `${env.appUrl}/campaigns/${card.id}` });
    ActionSheetIOS.showActionSheetWithOptions({ title: card.title, options: [tm('menuJoin'), tm('menuShare'), tm('cancel')], cancelButtonIndex: 2 }, (i) =>
      i === 0 ? open(card) : i === 1 ? void share() : undefined,
    );
  };
  const reload = () => Promise.all([page.reload(), meta.reload()]);
  const filtered = isFiltered(filters) || filters.sort !== 'newest';
  const reset = () => {
    setQ('');
    setFilters(DEFAULT_FILTERS);
  };

  const list = (
    <Screen
      title={t('title')}
      tabRoot
      refreshing={page.loading && !!page.data}
      onRefresh={reload}
      onEndReached={next && !moreError ? loadMore : undefined}
      banner={<OfflineBanner load={page} />}
    >
      {meta.data?.banners.length ? (
        <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 10 }} accessibilityLabel={tm('banners')}>
          {meta.data.banners.map((b) => (
            <Pressable
              key={b.img}
              accessibilityRole="link"
              accessibilityLabel={b.alt || undefined}
              onPress={() => {
                const r = nativeRoute(b.href);
                if (r) router.push(r as never);
                else void Linking.openURL(b.href);
              }}
            >
              <Image source={{ uri: b.img }} style={{ width: 300, aspectRatio: 16 / 7, borderRadius: radius.card, backgroundColor: c.subtle }} resizeMode="cover" />
            </Pressable>
          ))}
        </ScrollView>
      ) : null}
      {meta.data && !meta.data.verified ? (
        <Alert tone="warn" title={t('connectTitle')} action={{ label: t('connectAction'), onPress: () => router.push({ pathname: '/social', params: { next: '/' } }) }}>
          {t('connectBody')}
        </Alert>
      ) : null}
      <Row gap={8} style={{ flexWrap: 'nowrap', alignItems: 'flex-end' }}>
        <View style={{ flex: 1 }}>
          <Field label={t('search')} placeholder={t('searchPlaceholder')} value={q} onChangeText={setQ} returnKeyType="search" clearButtonMode="while-editing" onSubmitEditing={() => setFilters({ q: q.trim().slice(0, 80) })} />
        </View>
        {q && RN.OS !== 'ios' ? (
          <Pressable accessibilityRole="button" accessibilityLabel={t('clearSearch')} onPress={() => setQ('')} style={{ width: 48, height: 48, alignItems: 'center', justifyContent: 'center' }}>
            <Icon name="close" size={22} color={c.muted} />
          </Pressable>
        ) : null}
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={tm('filters')}
          testID="open-filters"
          onPress={() => router.push('/filters')}
          android_ripple={{ color: c.border, borderless: true }}
          style={{ width: 48, height: 48, borderRadius: radius.control, borderWidth: 1.5, borderColor: filtered ? c.primary : c.borderStrong, backgroundColor: filtered ? c.primarySoft : c.surface, alignItems: 'center', justifyContent: 'center' }}
        >
          <Icon name="tune" size={22} color={filtered ? c.primarySoftFg : c.text2} />
        </Pressable>
      </Row>
      <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
        <Chip label={t('allPlatforms')} active={!filters.platform} onPress={() => (haptic.selection(), setFilters({ platform: '' }))} />
        {(meta.data?.platforms ?? []).map((p) => (
          <Chip key={p} label={platformLabels[p]} platform={p} active={filters.platform === p} onPress={() => (haptic.selection(), setFilters({ platform: p }))} />
        ))}
      </ScrollView>
      {filtered ? (
        <Button variant="link" size="sm" icon="close" onPress={reset}>{t('reset')}</Button>
      ) : null}
      {page.error && (!page.data || !page.stale) ? (
        <EmptyState icon="wifi_off" title={t('loadError')} body={err(page.error)} action={{ label: t('retry'), onPress: page.reload }} />
      ) : !page.data ? (
        [0, 1].map((i) => <View key={i} style={{ height: 320, borderRadius: radius.card, backgroundColor: c.subtle }} />)
      ) : !items.length ? (
        filtered ? (
          <EmptyState icon="search" title={t('emptyFilteredTitle')} body={t('emptyFilteredBody')} action={{ label: t('reset'), onPress: reset }} />
        ) : (
          <EmptyState icon="campaign" title={t('emptyTitle')} body={t('emptyBody')} action={{ label: t('emptyAction'), onPress: () => router.push('/social') }} />
        )
      ) : (
        <View accessibilityLabel={t('listLabel')} style={{ gap: 14 }}>
          {items.map((card) => {
            const fix = card.ctaState === 'not_eligible' ? fixKey(card.ctaReason) : null;
            return (
              <CampaignCardView
                key={card.id}
                card={card}
                locale={locale}
                selected={wide && selected === card.id}
                onOpen={() => open(card)}
                onLongPress={RN.OS === 'ios' ? () => menu(card) : undefined}
                reasonText={card.ctaState === 'not_eligible' && card.ctaReason ? err(`not_eligible:${card.ctaReason}`) : null}
                fix={fix ? { label: tc(`fix.${fix}`), onPress: () => runFix(fix, router, card.id) } : null}
              />
            );
          })}
        </View>
      )}
      {loadingMore ? <Txt variant="caption" tone="muted" style={{ textAlign: 'center' }}>{t('loadingMore')}</Txt> : null}
      {moreError ? <Alert tone="danger" action={{ label: t('retry'), onPress: loadMore }}>{err(moreError)}</Alert> : null}
      {!next && items.length > 3 ? <Txt variant="caption" tone="muted" style={{ textAlign: 'center' }}>{t('end')}</Txt> : null}
    </Screen>
  );

  if (!wide) return list;
  return (
    <View style={{ flex: 1, flexDirection: 'row', backgroundColor: c.canvas }}>
      <View style={{ width: 420, borderRightWidth: 1, borderColor: c.border }}>{list}</View>
      <View style={{ flex: 1 }}>
        {selected ?? items[0]?.id ? <CampaignDetail key={selected ?? items[0]!.id} id={selected ?? items[0]!.id} embedded /> : <EmptyState icon="campaign" title={t('emptyTitle')} />}
      </View>
    </View>
  );
}
