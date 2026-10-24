// Pita offline / data basi (DS Android 03 "Offline duluan"): data terakhir tetap tampil dengan waktu update-nya.
import { useNetInfo } from '@react-native-community/netinfo';
import { useLocale, useTranslations } from 'use-intl';
import { formatRelative } from '@clipper/ui/format';
import type { Loaded } from '../data';
import { useTheme } from '../theme';
import { Icon, Row, Txt } from './core';

export function useOnline() {
  return useNetInfo().isConnected !== false;
}

export function OfflineBanner({ load }: { load: Pick<Loaded<unknown>, 'stale' | 'updatedAt' | 'data'> }) {
  const t = useTranslations('clipper.mobile');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const { c, radius } = useTheme();
  const online = useOnline();
  if (online && !load.stale) return null;
  if (!load.data) return null;
  const when = load.updatedAt ? formatRelative(new Date(load.updatedAt).toISOString(), Date.now(), locale) : null;
  return (
    <Row gap={8} style={{ backgroundColor: c.warnBg, borderRadius: radius.control, paddingHorizontal: 12, paddingVertical: 10, flexWrap: 'nowrap' }}>
      <Icon name="cloud_off" size={18} color={c.warnFg} />
      <Txt variant="caption" weight="600" tone="warnFg" style={{ flex: 1 }} accessibilityLiveRegion="polite">
        {online ? t('staleData', { when: when ?? '—' }) : t('offline', { when: when ?? '—' })}
      </Txt>
    </Row>
  );
}
