// Snackbar (DS Motion 25 #8 "masuk 300 decelerate · tampil 4 s", aksi URUNGKAN) untuk hasil aksi ringan:
// claim, kirim clip, tarik saldo, lepas pengaturan. Satu antrean di root, di atas nav bar.
import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { AccessibilityInfo, Pressable, View } from 'react-native';
import Animated, { FadeInDown, FadeOutDown } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useTheme } from '../theme';
import { Icon, Txt } from './core';

type Toast = { id: number; title: string; body?: string; tone?: 'success' | 'danger' | 'neutral'; action?: { label: string; onPress: () => void }; ms?: number };
type Show = (t: Omit<Toast, 'id'>) => void;

const Ctx = createContext<Show>(() => {});
export const useToast = () => useContext(Ctx);

export function ToastProvider({ children, bottomOffset = 96 }: { children: ReactNode; bottomOffset?: number }) {
  const { c, radius } = useTheme();
  const insets = useSafeAreaInsets();
  const [toast, setToast] = useState<Toast | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const seq = useRef(0);
  const show = useCallback<Show>((t) => {
    if (timer.current) clearTimeout(timer.current);
    const next = { ...t, id: ++seq.current };
    setToast(next);
    AccessibilityInfo.announceForAccessibility([t.title, t.body].filter(Boolean).join('. '));
    timer.current = setTimeout(() => setToast((x) => (x?.id === next.id ? null : x)), t.ms ?? 4000);
  }, []);
  useEffect(() => () => void (timer.current && clearTimeout(timer.current)), []);
  return (
    <Ctx.Provider value={show}>
      {children}
      {toast ? (
        <Animated.View
          key={toast.id}
          entering={FadeInDown.duration(300)}
          exiting={FadeOutDown.duration(200)}
          pointerEvents="box-none"
          style={{ position: 'absolute', left: 12, right: 12, bottom: insets.bottom + bottomOffset }}
        >
          <View accessibilityRole="alert" style={{ backgroundColor: c.inverse, borderRadius: radius.control, paddingVertical: 12, paddingHorizontal: 16, flexDirection: 'row', alignItems: 'center', gap: 12, elevation: 6, shadowColor: '#0a1226', shadowOpacity: 0.3, shadowRadius: 16, shadowOffset: { width: 0, height: 8 } }}>
            {toast.tone && toast.tone !== 'neutral' ? <Icon name={toast.tone === 'success' ? 'check_circle' : 'error'} size={20} color={toast.tone === 'success' ? c.successBg : c.dangerBg} filled /> : null}
            <View style={{ flex: 1, gap: 2 }}>
              <Txt variant="bodyS" weight="700" style={{ color: c.inverseFg }}>{toast.title}</Txt>
              {toast.body ? <Txt variant="caption" style={{ color: c.inverseFg, opacity: 0.8 }}>{toast.body}</Txt> : null}
            </View>
            {toast.action ? (
              <Pressable
                accessibilityRole="button"
                hitSlop={10}
                onPress={() => {
                  toast.action!.onPress();
                  setToast(null);
                }}
                style={{ minHeight: 44, justifyContent: 'center' }}
              >
                <Txt variant="label" weight="800" style={{ color: c.primarySoft, letterSpacing: 0.5 }}>{toast.action.label}</Txt>
              </Pressable>
            ) : null}
          </View>
        </Animated.View>
      ) : null}
    </Ctx.Provider>
  );
}
