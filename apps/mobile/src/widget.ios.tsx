// Widget iOS (DS iOS 05 "Widget small + medium", expo-widgets → SwiftUI): ClipperBalance (small) = saldo + jadwal cair;
// ClipperCampaigns (medium) = clip nunggu review + campaign baru yang cocok. Fungsi 'widget' di-stringify dan jalan di
// extension tanpa kode app, jadi isinya mandiri dan semua teks datang dari snapshot (src/widget-snapshot.ts).
// Diperbarui app saat aktif (WidgetKit tidak menjalankan JS app di latar).
import { HStack, Link, Spacer, Text, VStack } from '@expo/ui/swift-ui';
import { containerBackground, font, foregroundStyle, lineLimit, minimumScaleFactor, padding, widgetURL } from '@expo/ui/swift-ui/modifiers';
import { createWidget, type WidgetEnvironment } from 'expo-widgets';
import { loadWidgetSnapshot } from './widget-load';
import type { WidgetSnapshot } from './widget-snapshot';

// Navy di terang & gelap (kartu saldo DS); mode tinted/accented iOS 18 diwarnai sistem.
const Balance = createWidget<Partial<WidgetSnapshot>>('ClipperBalance', (s: Partial<WidgetSnapshot>) => {
  'widget';
  return (
    <VStack alignment="leading" spacing={4} modifiers={[containerBackground('#0a1226', 'widget'), widgetURL('clipper://wallet')]}>
      <Text modifiers={[font({ textStyle: 'caption', weight: 'semibold' }), foregroundStyle('#c7cede')]}>{s.titleShort ?? 'Clipper'}</Text>
      <Text modifiers={[font({ size: 28, weight: 'bold', design: 'rounded' }), foregroundStyle('#ffffff'), minimumScaleFactor(0.5), lineLimit(1)]}>
        {s.signedIn ? (s.balanceShort ?? '—') : '—'}
      </Text>
      <Spacer />
      <Text modifiers={[font({ textStyle: 'caption', weight: 'semibold' }), foregroundStyle('#5f8bff'), lineLimit(2)]}>
        {s.signedIn ? (s.release ?? '') : (s.signIn ?? '')}
      </Text>
    </VStack>
  );
});

const Campaigns = createWidget<Partial<WidgetSnapshot>>('ClipperCampaigns', (s: Partial<WidgetSnapshot>, env: WidgetEnvironment) => {
  'widget';
  const dark = env.colorScheme === 'dark';
  const ink = dark ? '#f6f8fc' : '#0a1226';
  const muted = dark ? '#a6b0c4' : '#5b6479';
  const list = s.campaigns ?? [];
  return (
    <VStack alignment="leading" spacing={6} modifiers={[containerBackground(dark ? '#111a33' : '#ffffff', 'widget'), widgetURL('clipper://')]}>
      <Link destination="clipper://clips">
        <HStack spacing={6}>
          <Text modifiers={[font({ textStyle: 'caption', weight: 'bold' }), foregroundStyle('#1d5bff')]}>{s.reviewLabel ?? ''}</Text>
          <Text modifiers={[font({ textStyle: 'caption' }), foregroundStyle(muted), lineLimit(1)]}>{s.signedIn ? (s.reviewLine ?? '') : (s.signIn ?? '')}</Text>
        </HStack>
      </Link>
      <Text modifiers={[font({ textStyle: 'subheadline', weight: 'bold' }), foregroundStyle(ink)]}>{s.forYou ?? 'Clipper'}</Text>
      {list.length ? (
        list.slice(0, 2).map((c) => (
          <Link key={c.url} destination={c.url}>
            <HStack spacing={8}>
              <VStack alignment="leading" spacing={1}>
                <Text modifiers={[font({ textStyle: 'footnote', weight: 'semibold' }), foregroundStyle(ink), lineLimit(1)]}>{c.title}</Text>
                <Text modifiers={[font({ textStyle: 'caption2' }), foregroundStyle(muted), lineLimit(1)]}>{c.sub}</Text>
              </VStack>
              <Spacer />
              <Text modifiers={[font({ textStyle: 'footnote', weight: 'bold' }), foregroundStyle('#1d5bff')]}>{c.rate}</Text>
            </HStack>
          </Link>
        ))
      ) : (
        <Text modifiers={[font({ textStyle: 'footnote' }), foregroundStyle(muted), padding({ top: 4 })]}>{s.empty ?? ''}</Text>
      )}
    </VStack>
  );
});

export async function refreshWidgets() {
  const s = await loadWidgetSnapshot().catch(() => null);
  if (!s) return;
  Balance.updateSnapshot(s);
  Campaigns.updateSnapshot(s);
}
