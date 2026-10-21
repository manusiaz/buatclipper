// Komponen dasar native = padanan @clipper/ui (DS): ikon & tanda platform memakai path yang sama, warna/ukuran dari token.
import type { ReactNode } from 'react';
import { ActivityIndicator, Pressable, Text, TextInput, View, type StyleProp, type TextInputProps, type TextStyle, type ViewStyle } from 'react-native';
import Svg, { Path } from 'react-native-svg';
import { ICON_VIEWBOX, iconAliases, iconPaths, type IconName } from '@clipper/ui/icons';
import { PLATFORM_PATHS, platformLabels, type Platform } from '@clipper/ui/platform-paths';
import { cardShadow, fontFor, useTheme, type TextVariant } from '../theme';

export type { IconName, Platform };

export function Icon({ name, size = 20, filled = false, color }: { name: IconName; size?: number; filled?: boolean; color?: string }) {
  const { c } = useTheme();
  const key = (name in iconAliases ? iconAliases[name as keyof typeof iconAliases] : name) as keyof typeof iconPaths;
  const paths: readonly string[] = iconPaths[key];
  return (
    <Svg width={size} height={size} viewBox={ICON_VIEWBOX} accessible={false}>
      <Path d={(filled ? paths[1] : undefined) ?? paths[0]!} fill={color ?? c.ink} />
    </Svg>
  );
}

export function PlatformIcon({ platform, size = 16, color }: { platform: Platform; size?: number; color?: string }) {
  const { c } = useTheme();
  const { d, evenOdd } = PLATFORM_PATHS[platform];
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24" accessible={false}>
      <Path d={d} fill={color ?? c.ink} fillRule={evenOdd ? 'evenodd' : undefined} />
    </Svg>
  );
}

type Tone = 'ink' | 'text2' | 'muted' | 'faint' | 'primary' | 'success' | 'danger' | 'warnFg' | 'primaryFg' | 'successFg' | 'dangerFg';

export function Txt({
  variant = 'body',
  tone = 'ink',
  weight,
  style,
  numberOfLines,
  children,
  ...a11y
}: {
  variant?: TextVariant;
  tone?: Tone;
  weight?: '400' | '500' | '600' | '700' | '800';
  style?: StyleProp<TextStyle>;
  numberOfLines?: number;
  children: ReactNode;
  accessibilityRole?: 'header' | 'text' | 'link';
}) {
  const { c, text } = useTheme();
  const t = text[variant] as { fontSize: number; lineHeight?: number; letterSpacing?: number; fontWeight?: string };
  const w = weight ?? t.fontWeight ?? '400';
  return (
    <Text
      numberOfLines={numberOfLines}
      {...a11y}
      style={[{ fontSize: t.fontSize, lineHeight: t.lineHeight, letterSpacing: t.letterSpacing, fontFamily: fontFor(w), color: c[tone] }, style]}
    >
      {children}
    </Text>
  );
}

export type ButtonVariant = 'primary' | 'secondary' | 'ink' | 'ghost' | 'link' | 'danger';

export function Button({
  children,
  onPress,
  variant = 'primary',
  size = 'md',
  icon,
  iconRight,
  loading,
  disabled,
  full,
  testID,
  accessibilityLabel,
}: {
  children: ReactNode;
  onPress?: () => void;
  variant?: ButtonVariant;
  size?: 'sm' | 'md' | 'lg';
  icon?: IconName;
  iconRight?: IconName;
  loading?: boolean;
  disabled?: boolean;
  full?: boolean;
  testID?: string;
  accessibilityLabel?: string;
}) {
  const { c, radius } = useTheme();
  const off = disabled || loading;
  const bg = { primary: c.primary, secondary: c.surface, ink: c.inverse, ghost: 'transparent', link: 'transparent', danger: c.danger }[variant];
  const fg = { primary: c.primaryFg, secondary: c.ink, ink: c.inverseFg, ghost: c.ink, link: c.link, danger: c.primaryFg }[variant];
  const h = { sm: 36, md: 44, lg: 52 }[size];
  return (
    <Pressable
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel}
      accessibilityState={{ disabled: !!off, busy: !!loading }}
      disabled={off}
      onPress={onPress}
      style={({ pressed }) => [
        {
          minHeight: variant === 'link' ? undefined : h,
          paddingHorizontal: variant === 'link' ? 0 : size === 'sm' ? 12 : 18,
          borderRadius: radius.control,
          backgroundColor: off && variant !== 'link' && variant !== 'ghost' ? c.disabled : bg,
          borderWidth: variant === 'secondary' ? 1.5 : 0,
          borderColor: c.borderStrong,
          flexDirection: 'row',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 8,
          alignSelf: full ? 'stretch' : 'flex-start',
          opacity: pressed ? 0.85 : 1,
        },
        variant === 'primary' && !off ? { shadowColor: c.primary, shadowOpacity: 0.35, shadowRadius: 12, shadowOffset: { width: 0, height: 8 }, elevation: 2 } : null,
      ]}
    >
      {loading ? <ActivityIndicator size="small" color={fg} /> : icon ? <Icon name={icon} size={18} color={off ? c.disabledFg : fg} /> : null}
      <Text style={{ fontFamily: fontFor('700'), fontSize: size === 'sm' ? 14 : 15, color: off && variant !== 'link' ? c.disabledFg : fg }}>{children}</Text>
      {iconRight && !loading ? <Icon name={iconRight} size={18} color={off ? c.disabledFg : fg} /> : null}
    </Pressable>
  );
}

export function Card({ children, style, padding = 16 }: { children: ReactNode; style?: StyleProp<ViewStyle>; padding?: number }) {
  const { c, radius, mode } = useTheme();
  return (
    <View
      style={[
        { backgroundColor: c.surface, borderRadius: radius.card, padding, borderWidth: mode === 'dark' ? 1 : 0, borderColor: c.border, gap: 10 },
        mode === 'light' ? cardShadow : null,
        style,
      ]}
    >
      {children}
    </View>
  );
}

const BADGE = {
  neutral: ['subtle', 'text2'],
  primary: ['primarySoft', 'primarySoftFg'],
  success: ['successBg', 'successFg'],
  warn: ['warnBg', 'warnFg'],
  danger: ['dangerBg', 'dangerFg'],
} as const;

export function Badge({ children, tone = 'neutral', icon }: { children: ReactNode; tone?: keyof typeof BADGE; icon?: IconName }) {
  const { c } = useTheme();
  const [bg, fg] = BADGE[tone];
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4, alignSelf: 'flex-start', backgroundColor: c[bg], borderRadius: 999, paddingHorizontal: 8, paddingVertical: 3 }}>
      {icon ? <Icon name={icon} size={13} color={c[fg]} /> : null}
      <Text style={{ fontFamily: fontFor('700'), fontSize: 12, color: c[fg] }}>{children}</Text>
    </View>
  );
}

export function PlatformChip({ platform }: { platform: Platform }) {
  const { c } = useTheme();
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 4, backgroundColor: c.subtle, borderRadius: 999, paddingHorizontal: 8, height: 24 }}>
      <PlatformIcon platform={platform} size={13} color={c.text2} />
      <Text style={{ fontFamily: fontFor('700'), fontSize: 12, color: c.text2 }}>{platformLabels[platform]}</Text>
    </View>
  );
}

export function ProgressBar({ value, tone = 'primary' }: { value: number; tone?: 'primary' | 'warn' | 'danger' }) {
  const { c } = useTheme();
  const v = Math.min(1, Math.max(0, value));
  return (
    <View style={{ height: 6, borderRadius: 999, backgroundColor: c.subtle, overflow: 'hidden' }} accessibilityRole="progressbar" accessibilityValue={{ min: 0, max: 100, now: Math.round(v * 100) }}>
      <View style={{ width: `${v * 100}%`, height: '100%', backgroundColor: c[tone], borderRadius: 999 }} />
    </View>
  );
}

const ALERT = { info: ['infoBg', 'infoBorder', 'infoFg', 'info'], warn: ['warnBg', 'warnBorder', 'warnFg', 'error'], danger: ['dangerBg', 'dangerBorder', 'dangerFg', 'error'], success: ['successBg', 'successBorder', 'successFg', 'check_circle'] } as const;

export function Alert({ tone = 'info', title, children, action }: { tone?: keyof typeof ALERT; title?: string; children?: ReactNode; action?: { label: string; onPress: () => void } }) {
  const { c, radius } = useTheme();
  const [bg, border, fg, icon] = ALERT[tone];
  return (
    <View accessibilityRole="alert" style={{ flexDirection: 'row', gap: 10, backgroundColor: c[bg], borderColor: c[border], borderWidth: 1, borderRadius: radius.cardSm, padding: 12 }}>
      <Icon name={icon as IconName} size={20} color={c[fg]} filled />
      <View style={{ flex: 1, gap: 4 }}>
        {title ? <Txt variant="label" weight="700" style={{ color: c[fg] }}>{title}</Txt> : null}
        {children ? <Txt variant="bodyS" style={{ color: c[fg] }}>{children}</Txt> : null}
        {action ? <Button variant="secondary" size="sm" onPress={action.onPress}>{action.label}</Button> : null}
      </View>
    </View>
  );
}

export function EmptyState({ icon, title, body, action }: { icon: IconName; title: string; body?: string; action?: { label: string; onPress: () => void } }) {
  const { c } = useTheme();
  return (
    <Card style={{ alignItems: 'center', paddingVertical: 28 }}>
      <View style={{ width: 52, height: 52, borderRadius: 16, backgroundColor: c.primarySoft, alignItems: 'center', justifyContent: 'center' }}>
        <Icon name={icon} size={26} color={c.primarySoftFg} filled />
      </View>
      <Txt variant="h6" style={{ textAlign: 'center' }}>{title}</Txt>
      {body ? <Txt variant="bodyS" tone="muted" style={{ textAlign: 'center' }}>{body}</Txt> : null}
      {action ? <Button onPress={action.onPress}>{action.label}</Button> : null}
    </Card>
  );
}

export function Field({ label, helper, error, ...input }: TextInputProps & { label: string; helper?: string; error?: string }) {
  const { c, radius } = useTheme();
  return (
    <View style={{ gap: 6 }}>
      <Txt variant="label" weight="600">{label}</Txt>
      <TextInput
        placeholderTextColor={c.placeholder}
        accessibilityLabel={label}
        {...input}
        style={[
          { minHeight: 48, borderRadius: radius.control, borderWidth: 1.5, borderColor: error ? c.danger : c.borderStrong, backgroundColor: c.surface, color: c.ink, paddingHorizontal: 14, fontFamily: fontFor('500'), fontSize: 16 },
          input.style,
        ]}
      />
      {error ? <Txt variant="caption" tone="danger">{error}</Txt> : helper ? <Txt variant="caption" tone="muted">{helper}</Txt> : null}
    </View>
  );
}

export function Row({ children, gap = 8, style }: { children: ReactNode; gap?: number; style?: StyleProp<ViewStyle> }) {
  return <View style={[{ flexDirection: 'row', alignItems: 'center', gap, flexWrap: 'wrap' }, style]}>{children}</View>;
}

/** Tile brand DS: biru, radius 30 %, pesawat kertas −32° (sama dengan LogoMark web). */
export function LogoMark({ size = 34 }: { size?: number }) {
  const { c } = useTheme();
  return (
    <View style={{ width: size, height: size, borderRadius: size * 0.3, backgroundColor: c.primary, alignItems: 'center', justifyContent: 'center' }}>
      <View style={{ transform: [{ rotate: '-32deg' }, { translateX: size * 0.04 }, { translateY: -size * 0.04 }] }}>
        <Icon name="send" filled size={Math.round(size * 0.59)} color="#ffffff" />
      </View>
    </View>
  );
}

export function Logo({ size = 28 }: { size?: number }) {
  return (
    <Row gap={8}>
      <LogoMark size={size} />
      <Txt variant="h5" weight="800">Clipper</Txt>
    </Row>
  );
}
