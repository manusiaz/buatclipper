// Extended FAB M3 (DS Android 01 "satu FAB, pojok kanan bawah, di atas nav bar"; Motion 25 #6): label hilang saat
// scroll turun (300 ms), muncul lagi saat naik. iOS tidak memakai FAB (aksi utama di nav bar).
import Animated, { FadeIn, FadeOut, LinearTransition } from 'react-native-reanimated';
import { Pressable } from 'react-native';
import { useTheme } from '../theme';
import { Icon, Txt, type IconName } from './core';

export function ExtendedFab({ icon, label, onPress, collapsed, testID }: { icon: IconName; label: string; onPress: () => void; collapsed: boolean; testID?: string }) {
  const { c } = useTheme();
  return (
    <Animated.View layout={LinearTransition.duration(300)} style={{ position: 'absolute', right: 16, bottom: 16, borderRadius: 16, overflow: 'hidden', elevation: 3, shadowColor: '#0a1226', shadowOpacity: 0.25, shadowRadius: 12, shadowOffset: { width: 0, height: 6 } }}>
      <Pressable
        testID={testID}
        accessibilityRole="button"
        accessibilityLabel={label}
        onPress={onPress}
        android_ripple={{ color: 'rgba(255,255,255,0.24)' }}
        style={{ minHeight: 56, minWidth: 56, paddingHorizontal: collapsed ? 16 : 20, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 12, backgroundColor: c.primary }}
      >
        <Icon name={icon} size={24} color={c.primaryFg} />
        {collapsed ? null : (
          <Animated.View entering={FadeIn.duration(200)} exiting={FadeOut.duration(100)}>
            <Txt variant="label" weight="700" tone="primaryFg">{label}</Txt>
          </Animated.View>
        )}
      </Pressable>
    </Animated.View>
  );
}
