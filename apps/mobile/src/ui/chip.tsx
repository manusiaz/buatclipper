// Chip filter (DS 11 Filter): pill, aktif = biru lembut.
import { Pressable } from 'react-native';
import type { Platform } from '@clipper/ui/platform-paths';
import { fontFor, useTheme } from '../theme';
import { PlatformIcon, Txt } from './core';

export function Chip({ label, active, onPress, platform }: { label: string; active?: boolean; onPress: () => void; platform?: Platform }) {
  const { c } = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ selected: !!active }}
      onPress={onPress}
      hitSlop={{ top: 6, bottom: 6 }}
      style={{ flexDirection: 'row', alignItems: 'center', gap: 6, minHeight: 36, paddingHorizontal: 14, borderRadius: 999, borderWidth: 1.5, borderColor: active ? c.primary : c.borderStrong, backgroundColor: active ? c.primarySoft : c.surface }}
    >
      {platform ? <PlatformIcon platform={platform} size={14} color={active ? c.primarySoftFg : c.text2} /> : null}
      <Txt variant="label" weight="600" style={{ color: active ? c.primarySoftFg : c.text2, fontFamily: fontFor('600') }}>{label}</Txt>
    </Pressable>
  );
}
