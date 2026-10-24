// Widget layar utama Android (DS Android 05 "Widget 4×2 + 2×2"): Balance 4×2 = saldo + jadwal cair + ditahan,
// campaign baru + rate tertinggi, clip nunggu review; BalanceSmall 2×2 = saldo + jadwal cair. Dirender handler
// headless (sistem memanggil tiap updatePeriodMillis / saat ditambahkan) dan di-refresh saat app aktif.
import { FlexWidget, TextWidget, requestWidgetUpdate, type WidgetTaskHandler } from 'react-native-android-widget';
import { tokens } from './tokens.gen';
import { loadWidgetSnapshot } from './widget-load';
import type { WidgetSnapshot } from './widget-snapshot';

const c = tokens.light;
const hex = (v: string) => v as `#${string}`;
const SOFT = '#c7cede';

function BalancePanel({ s, small }: { s: WidgetSnapshot; small?: boolean }) {
  return (
    <FlexWidget
      clickAction="OPEN_URI"
      clickActionData={{ uri: 'clipper://wallet' }}
      accessibilityLabel={s.signedIn ? [s.title, s.balance, s.release, s.held].filter(Boolean).join(', ') : s.signIn}
      style={{ height: 'match_parent', width: small ? 'match_parent' : 0, flex: small ? undefined : 1, backgroundColor: hex(c.navy), borderRadius: 18, padding: 14, justifyContent: 'center', flexGap: 2 }}
    >
      <TextWidget text={small ? s.titleShort : s.title} style={{ fontSize: 12, color: SOFT }} maxLines={1} truncate="END" />
      <TextWidget text={s.signedIn ? (small ? s.balanceShort : s.balance) : '—'} style={{ fontSize: small ? 22 : 24, fontWeight: '700', color: '#ffffff', adjustsFontSizeToFit: true }} maxLines={1} />
      <TextWidget text={s.signedIn ? s.release : s.signIn} style={{ fontSize: 11, color: '#ffffff' }} maxLines={2} truncate="END" />
      {!small && s.held ? <TextWidget text={s.held} style={{ fontSize: 11, color: SOFT }} maxLines={1} truncate="END" /> : null}
    </FlexWidget>
  );
}

function Tile({ uri, label, value, hint }: { uri: string; label: string; value: string; hint: string }) {
  return (
    <FlexWidget
      clickAction="OPEN_URI"
      clickActionData={{ uri }}
      accessibilityLabel={`${label} ${value}, ${hint}`}
      style={{ flex: 1, width: 'match_parent', backgroundColor: hex(c.surface), borderRadius: 14, paddingHorizontal: 12, paddingVertical: 8, justifyContent: 'center' }}
    >
      <TextWidget text={label} style={{ fontSize: 11, color: hex(c.muted) }} maxLines={1} truncate="END" />
      <TextWidget text={value} style={{ fontSize: 18, fontWeight: '700', color: hex(c.ink) }} maxLines={1} />
      <TextWidget text={hint} style={{ fontSize: 10, color: hex(c.muted) }} maxLines={1} truncate="END" />
    </FlexWidget>
  );
}

function Balance({ s }: { s: WidgetSnapshot }) {
  return (
    <FlexWidget style={{ height: 'match_parent', width: 'match_parent', flexDirection: 'row', flexGap: 8, backgroundColor: hex(c.surface2), borderRadius: 22, padding: 8 }}>
      <BalancePanel s={s} />
      {s.signedIn ? (
        <FlexWidget style={{ flex: 1, height: 'match_parent', flexGap: 8 }}>
          <Tile uri="clipper://" label={s.newLabel} value={s.newCount} hint={`${s.rateLabel} ${s.topRate}`} />
          <Tile uri="clipper://clips" label={s.reviewLabel} value={s.reviewCount} hint={s.reviewLine} />
        </FlexWidget>
      ) : null}
    </FlexWidget>
  );
}

const FALLBACK = { title: 'Clipper', titleShort: 'Clipper', signIn: '—', signedIn: false } as WidgetSnapshot;
const snapshot = () => loadWidgetSnapshot().catch(() => FALLBACK);
const view = (name: string, s: WidgetSnapshot) => (name === 'BalanceSmall' ? <BalancePanel s={s} small /> : <Balance s={s} />);

export const widgetTaskHandler: WidgetTaskHandler = async ({ widgetInfo, widgetAction, renderWidget }) => {
  if (widgetAction === 'WIDGET_ADDED' || widgetAction === 'WIDGET_UPDATE' || widgetAction === 'WIDGET_RESIZED') renderWidget(view(widgetInfo.widgetName, await snapshot()));
};

/** Dipanggil saat app aktif / sesudah aksi yang mengubah saldo; satu muatan data untuk kedua ukuran. */
export async function refreshWidgets() {
  const s = await snapshot();
  await Promise.all(['Balance', 'BalanceSmall'].map((widgetName) => requestWidgetUpdate({ widgetName, renderWidget: () => view(widgetName, s) })));
}
