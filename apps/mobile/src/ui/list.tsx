// Daftar pengaturan/menu: grup kartu (iOS inset grouped list), baris 56 dp Android / 48 pt iOS, ikon di kotak tint,
// chevron untuk navigasi, ikon open_in_new untuk halaman web.
import type { ReactNode } from 'react';
import { Platform, Pressable, View } from 'react-native';
import { useTheme } from '../theme';
import { Icon, Txt, type IconName } from './core';

export function ListSection({ title, children, footer }: { title?: string; children: ReactNode; footer?: string }) {
  const { c, radius, mode } = useTheme();
  return (
    <View style={{ gap: 6 }}>
      {title ? <Txt variant="caption" weight="700" tone="muted" style={{ paddingHorizontal: 4, textTransform: Platform.OS === 'ios' ? 'uppercase' : 'none' }} accessibilityRole="header">{title}</Txt> : null}
      <View style={{ backgroundColor: c.surface, borderRadius: radius.card, overflow: 'hidden', borderWidth: mode === 'dark' ? 1 : 0, borderColor: c.border }}>{children}</View>
      {footer ? <Txt variant="caption" tone="muted" style={{ paddingHorizontal: 4 }}>{footer}</Txt> : null}
    </View>
  );
}

export function ListRow({
  icon,
  label,
  detail,
  onPress,
  external,
  danger,
  dot,
  right,
  first,
  testID,
}: {
  icon?: IconName;
  label: string;
  detail?: string;
  onPress?: () => void;
  external?: boolean;
  danger?: boolean;
  dot?: boolean;
  right?: ReactNode;
  first?: boolean;
  testID?: string;
}) {
  const { c } = useTheme();
  const fg = danger ? c.danger : c.ink;
  return (
    <Pressable
      testID={testID}
      accessibilityRole={external ? 'link' : 'button'}
      accessibilityLabel={detail ? `${label}, ${detail}` : label}
      onPress={onPress}
      disabled={!onPress}
      android_ripple={{ color: c.border }}
      style={({ pressed }) => ({ minHeight: Platform.OS === 'android' ? 56 : 48, flexDirection: 'row', alignItems: 'center', gap: 12, paddingHorizontal: 14, paddingVertical: 8, borderTopWidth: first ? 0 : 1, borderColor: c.border, backgroundColor: pressed && Platform.OS === 'ios' ? c.subtle : 'transparent' })}
    >
      {icon ? (
        <View style={{ width: 32, height: 32, borderRadius: 9, backgroundColor: danger ? c.dangerBg : c.primarySoft, alignItems: 'center', justifyContent: 'center' }}>
          <Icon name={icon} size={18} color={danger ? c.danger : c.primarySoftFg} />
        </View>
      ) : null}
      <View style={{ flex: 1, gap: 1 }}>
        <Txt variant="bodyS" weight="600" style={{ color: fg }}>{label}</Txt>
        {detail ? <Txt variant="caption" tone="muted" numberOfLines={2}>{detail}</Txt> : null}
      </View>
      {dot ? <View style={{ width: 10, height: 10, borderRadius: 5, backgroundColor: c.danger }} accessibilityLabel="!" /> : null}
      {right}
      {onPress && !right ? <Icon name={external ? 'open_in_new' : 'chevron_right'} size={external ? 18 : 22} color={c.faint} /> : null}
    </Pressable>
  );
}
