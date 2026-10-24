// Tab pill (DS 10 Tabs "pill fullWidth"; iOS segmented): pilih satu tampilan dalam satu layar.
import { Pressable, View } from 'react-native';
import { haptic } from '../haptics';
import { useTheme } from '../theme';
import { Icon, Txt, type IconName } from './core';

export function Segmented<K extends string>({ value, onChange, items, label }: { value: K; onChange: (k: K) => void; items: { key: K; label: string; icon?: IconName; count?: number }[]; label: string }) {
  const { c, radius } = useTheme();
  return (
    <View accessibilityRole="tablist" accessibilityLabel={label} style={{ flexDirection: 'row', backgroundColor: c.subtle, borderRadius: radius.control, padding: 4, gap: 4 }}>
      {items.map((it) => {
        const on = it.key === value;
        return (
          <Pressable
            key={it.key}
            accessibilityRole="tab"
            accessibilityState={{ selected: on }}
            testID={`seg-${it.key}`}
            onPress={() => {
              if (on) return;
              haptic.selection();
              onChange(it.key);
            }}
            style={{ flex: 1, minHeight: 40, borderRadius: radius.control - 4, backgroundColor: on ? c.surface : 'transparent', flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6 }}
          >
            {it.icon ? <Icon name={it.icon} size={18} color={on ? c.ink : c.muted} filled={on} /> : null}
            <Txt variant="label" weight={on ? '700' : '600'} tone={on ? undefined : 'muted'}>{it.label}</Txt>
            {it.count ? (
              <View style={{ minWidth: 20, height: 20, borderRadius: 10, backgroundColor: c.primarySoft, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 5 }}>
                <Txt variant="caption" weight="700" style={{ fontSize: 11, color: c.primarySoftFg }}>{String(it.count)}</Txt>
              </View>
            ) : null}
          </Pressable>
        );
      })}
    </View>
  );
}
