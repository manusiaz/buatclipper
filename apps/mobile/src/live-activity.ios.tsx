// Live Activity "Payout" (DS iOS 05 Dynamic Island & Motion 26 #4: "Lagi ditransfer Rp482rb · BCA •• 4821 · ±2 menit"):
// dimulai server lewat APNs push-to-start saat payout.processing dan diakhiri saat paid/failed/cancelled
// (db/identity/.../_shared/apns.ts). App hanya mendaftarkan layout + token: push-to-start (apns_start) dan token update
// tiap activity (apns_activity, ref = payout yang sedang diproses). Teks Indonesia seperti notifikasi server.
import { HStack, Image, ProgressView, Spacer, Text, VStack } from '@expo/ui/swift-ui';
import { activityBackgroundTint, font, foregroundStyle, lineLimit, monospacedDigit } from '@expo/ui/swift-ui/modifiers';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { addPushToStartTokenListener, createLiveActivity } from 'expo-widgets';
import { core, identityApi } from './supabase';

export type PayoutActivity = { payoutId?: string; amount?: number; bank?: string | null; last4?: string | null; etaAt?: string | null; startedAt?: string | null; status?: string };

const Payout = createLiveActivity<PayoutActivity>('Payout', (p: PayoutActivity) => {
  'widget';
  // Tanpa regex ber-backslash: plugin 'widget' menjadikan fungsi ini template string, backslash ikut hilang.
  const n = Math.round(Number(p.amount) || 0);
  const digits = String(n);
  let grouped = '';
  for (let i = 0; i < digits.length; i++) grouped += (i > 0 && (digits.length - i) % 3 === 0 ? '.' : '') + digits[i];
  const full = 'Rp' + grouped;
  const short = n >= 1e6 ? 'Rp' + (n / 1e6).toFixed(1).replace('.', ',').replace(',0', '') + 'jt' : n >= 1e3 ? 'Rp' + Math.round(n / 1e3) + 'rb' : full;
  const bank = p.bank ? String(p.bank).split('_').join(' ').toUpperCase() + (p.last4 ? ' •• ' + p.last4 : '') : '';
  const done = p.status === 'paid';
  const failed = p.status === 'failed';
  const title = done ? 'Sudah masuk' : failed ? 'Transfer gagal' : 'Lagi ditransfer';
  const start = p.startedAt ? new Date(p.startedAt) : new Date();
  const eta = p.etaAt ? new Date(p.etaAt) : null;
  const running = !done && !failed && eta && eta.getTime() > Date.now();
  const icon = done ? 'checkmark.circle.fill' : failed ? 'exclamationmark.circle.fill' : 'paperplane.fill';
  const tint = done ? '#22c55e' : failed ? '#ef4444' : '#5f8bff';
  const progress = running ? (
    <ProgressView timerInterval={{ lower: start, upper: eta! }} countsDown={false} modifiers={[foregroundStyle(tint)]} />
  ) : null;
  const sub = [bank, failed ? 'saldo kembali ke wallet' : null].filter(Boolean).join(' · ');
  return {
    banner: (
      <VStack alignment="leading" spacing={6} modifiers={[activityBackgroundTint('#0a1226')]}>
        <HStack spacing={10}>
          <Image systemName={icon} size={22} color={tint} />
          <VStack alignment="leading" spacing={2}>
            <Text modifiers={[font({ textStyle: 'caption', weight: 'semibold' }), foregroundStyle('#c7cede')]}>{'Clipper · ' + title}</Text>
            <Text modifiers={[font({ size: 26, weight: 'bold', design: 'rounded' }), foregroundStyle('#ffffff'), monospacedDigit()]}>{full}</Text>
          </VStack>
          <Spacer />
          {running ? <Text timerInterval={{ lower: new Date(), upper: eta! }} countsDown modifiers={[font({ textStyle: 'subheadline', weight: 'semibold' }), foregroundStyle('#ffffff'), monospacedDigit()]} /> : null}
        </HStack>
        {progress}
        {sub ? <Text modifiers={[font({ textStyle: 'caption' }), foregroundStyle('#c7cede'), lineLimit(1)]}>{sub}</Text> : null}
      </VStack>
    ),
    compactLeading: <Image systemName={icon} color={tint} />,
    compactTrailing: <Text modifiers={[font({ textStyle: 'caption', weight: 'bold' }), foregroundStyle('#ffffff'), monospacedDigit()]}>{short}</Text>,
    minimal: <Image systemName={icon} color={tint} />,
    expandedLeading: (
      <VStack alignment="leading" spacing={2}>
        <Text modifiers={[font({ textStyle: 'caption' }), foregroundStyle('#c7cede')]}>{title}</Text>
        <Text modifiers={[font({ textStyle: 'title3', weight: 'bold' }), foregroundStyle('#ffffff'), monospacedDigit()]}>{short}</Text>
      </VStack>
    ),
    expandedTrailing: running ? (
      <Text timerInterval={{ lower: new Date(), upper: eta! }} countsDown modifiers={[font({ textStyle: 'subheadline', weight: 'semibold' }), foregroundStyle('#ffffff'), monospacedDigit()]} />
    ) : (
      <Image systemName={icon} size={22} color={tint} />
    ),
    expandedBottom: (
      <VStack alignment="leading" spacing={4}>
        {progress}
        {sub ? <Text modifiers={[font({ textStyle: 'caption' }), foregroundStyle('#c7cede'), lineLimit(1)]}>{sub}</Text> : null}
      </VStack>
    ),
  };
});

const SAVED = 'clipper.apns.tokens';

async function remember(token: string) {
  const list = JSON.parse((await AsyncStorage.getItem(SAVED)) ?? '[]') as string[];
  if (!list.includes(token)) await AsyncStorage.setItem(SAVED, JSON.stringify([...list, token].slice(-20)));
}

async function save(token: string, kind: 'apns_start' | 'apns_activity', ref?: string) {
  const { error } = await identityApi.rpc('save_activity_token', { p_token: token, p_kind: kind, ...(ref ? { p_ref: ref } : {}) });
  if (!error) await remember(token.toLowerCase());
}

/**
 * Saat login / app aktif: daftar token push-to-start, lalu tautkan tiap activity yang sedang tampil ke payout yang
 * sedang diproses (props activity tak bisa dibaca dari JS). Tak ada payout diproses → activity basi diakhiri.
 */
export async function syncLiveActivities(uid: string): Promise<() => void> {
  const sub = addPushToStartTokenListener((e) => void save(e.activityPushToStartToken, 'apns_start'));
  const instances = Payout.getInstances();
  if (instances.length) {
    const { data } = await core.from('payouts').select('id').eq('user_id', uid).eq('status', 'processing').order('created_at', { ascending: false }).limit(1).maybeSingle();
    await Promise.all(
      instances.map(async (a) => {
        if (!data?.id) return a.end('default');
        const token = await a.getPushToken();
        if (token) await save(token, 'apns_activity', data.id);
        else a.addPushTokenListener((e) => void save(e.pushToken, 'apns_activity', data.id!));
      }),
    );
  }
  return () => sub.remove();
}

/** Keluar: hapus token APNs perangkat ini (selagi masih login) supaya pencairan akun lain tak muncul di layar kunci. */
export async function releaseLiveActivities() {
  const list = JSON.parse((await AsyncStorage.getItem(SAVED)) ?? '[]') as string[];
  if (list.length) await identityApi.from('push_subscriptions').delete().in('endpoint', list);
  await AsyncStorage.removeItem(SAVED);
  await Promise.all(Payout.getInstances().map((a) => a.end('immediate')));
}
