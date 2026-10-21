// "Tahan untuk tarik" (DS Motion 25/26: GESTURE_END / UIImpact .heavy pas bar penuh): tahan 1,2 dtk, bar terisi,
// lepas sebelum penuh = batal. Pembaca layar: aksi "activate" langsung menjalankan (tahan sulit untuk VoiceOver/TalkBack).
import { useRef } from 'react';
import { Pressable, View } from 'react-native';
import Animated, { cancelAnimation, Easing, runOnJS, useAnimatedStyle, useSharedValue, withTiming } from 'react-native-reanimated';
import { haptic } from '../haptics';
import { useTheme } from '../theme';
import { Icon, Txt, type IconName } from './core';

const HOLD_MS = 1200;

export function HoldButton({ label, hint, icon, onConfirm, disabled, testID }: { label: string; hint: string; icon?: IconName; onConfirm: () => void; disabled?: boolean; testID?: string }) {
  const { c, radius } = useTheme();
  const p = useSharedValue(0);
  const fired = useRef(false);
  const fire = () => {
    if (fired.current) return;
    fired.current = true;
    haptic.threshold();
    onConfirm();
  };
  const fill = useAnimatedStyle(() => ({ width: `${p.value * 100}%` }));
  return (
    <Pressable
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityHint={hint}
      accessibilityState={{ disabled: !!disabled }}
      accessibilityActions={[{ name: 'activate' }]}
      onAccessibilityAction={(e) => e.nativeEvent.actionName === 'activate' && !disabled && fire()}
      disabled={disabled}
      onPressIn={() => {
        fired.current = false;
        p.value = withTiming(1, { duration: HOLD_MS, easing: Easing.linear }, (done) => {
          if (done) runOnJS(fire)();
        });
      }}
      onPressOut={() => {
        if (fired.current) return;
        cancelAnimation(p);
        p.value = withTiming(0, { duration: 200 });
      }}
      style={{ minHeight: 56, borderRadius: radius.control, overflow: 'hidden', backgroundColor: disabled ? c.disabled : c.inverse, justifyContent: 'center' }}
    >
      <Animated.View style={[{ position: 'absolute', left: 0, top: 0, bottom: 0, backgroundColor: c.primary }, fill]} />
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8, paddingHorizontal: 16 }}>
        {icon ? <Icon name={icon} size={20} color={disabled ? c.disabledFg : c.inverseFg} /> : null}
        <View style={{ alignItems: 'center' }}>
          <Txt variant="label" weight="800" style={{ color: disabled ? c.disabledFg : c.inverseFg }}>{label}</Txt>
          <Txt variant="caption" style={{ color: disabled ? c.disabledFg : c.inverseFg, opacity: 0.75 }}>{hint}</Txt>
        </View>
      </View>
    </Pressable>
  );
}
