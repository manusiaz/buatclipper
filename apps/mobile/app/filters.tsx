// Sheet filter campaign (DS Motion 25 #5 bottom sheet "Filter campaign", iOS 26 #2 sheet): platform, kategori,
// status, urutan — sama dengan FilterBar web. Ditarik turun = tutup; pilihan langsung berlaku.
import { useRouter } from 'expo-router';
import { View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { enabledPlatforms } from '@clipper/clipper-lib/pure';
import { SORTS, STATUSES } from '@clipper/clipper-lib/filters';
import { platformLabels, type Platform } from '@clipper/ui/platform-paths';
import { categories, settings, useLoad } from '@/data';
import { DEFAULT_FILTERS, setFilters, useFilters } from '@/filters-store';
import { haptic } from '@/haptics';
import { Button, Row, Txt } from '@/ui/core';
import { Chip } from '@/ui/chip';
import { Screen } from '@/ui/screen';

export default function Filters() {
  const t = useTranslations('clipper.campaigns');
  const tm = useTranslations('clipper.mobile');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const router = useRouter();
  const f = useFilters();
  const cats = useLoad(() => categories(locale), [locale], `categories:${locale}`);
  const plats = useLoad(async () => enabledPlatforms((await settings(['public.flags.platforms']))['public.flags.platforms']) as Platform[], [], 'platforms');
  const pick = (next: Parameters<typeof setFilters>[0]) => {
    haptic.selection();
    setFilters(next);
  };
  const section = (label: string, children: React.ReactNode) => (
    <View style={{ gap: 8 }}>
      <Txt variant="label" weight="700">{label}</Txt>
      <Row gap={8}>{children}</Row>
    </View>
  );
  return (
    <Screen
      title={tm('filters')}
      footer={
        <Row gap={10} style={{ flexWrap: 'nowrap' }}>
          <Button variant="secondary" onPress={() => pick({ ...DEFAULT_FILTERS, q: f.q })}>{t('reset')}</Button>
          <View style={{ flex: 1 }}>
            <Button full testID="apply-filters" onPress={() => router.back()}>{tm('showResults')}</Button>
          </View>
        </Row>
      }
    >
      {section(
        t('platform'),
        <>
          <Chip label={t('allPlatforms')} active={!f.platform} onPress={() => pick({ platform: '' })} />
          {(plats.data ?? []).map((p) => (
            <Chip key={p} label={platformLabels[p]} platform={p} active={f.platform === p} onPress={() => pick({ platform: p })} />
          ))}
        </>,
      )}
      {section(
        t('category'),
        <>
          <Chip label={t('allCategories')} active={!f.category} onPress={() => pick({ category: '' })} />
          {[...(cats.data ?? new Map<string, string>()).entries()].map(([id, name]) => (
            <Chip key={id} label={name} active={f.category === id} onPress={() => pick({ category: id })} />
          ))}
        </>,
      )}
      {section(
        t('status'),
        STATUSES.map((s) => <Chip key={s} label={t(`statusFilter.${s}`)} active={f.status === s} onPress={() => pick({ status: s })} />),
      )}
      {section(
        t('sort'),
        SORTS.map((s) => <Chip key={s} label={t(`sortBy.${s}`)} active={f.sort === s} onPress={() => pick({ sort: s })} />),
      )}
    </Screen>
  );
}
