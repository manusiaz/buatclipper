// Widget layar utama Android "Saldo" (F-C08): saldo Rp tersedia + pending dari sesi app. Dirender handler headless
// (dipanggil sistem tiap updatePeriodMillis / saat ditambahkan) dan di-refresh saat Wallet dibuka. Tap → tab Wallet.
import AsyncStorage from '@react-native-async-storage/async-storage';
import { FlexWidget, TextWidget, requestWidgetUpdate, type WidgetTaskHandler } from 'react-native-android-widget';
import { formatIDR } from '@clipper/ui/format';
import id from '@clipper/i18n/messages/id/clipper';
import en from '@clipper/i18n/messages/en/clipper';
import { decodeClaims, isAdmin } from './claims';
import { wallet } from './data';
import { identity } from './supabase';
import { tokens } from './tokens.gen';

type View = { title: string; amount: string | null; sub: string };
const c = tokens.light;

async function load(): Promise<View> {
  const locale = (await AsyncStorage.getItem('clipper.locale')) === 'en' ? 'en' : 'id';
  const m = locale === 'en' ? en : id;
  const { data } = await identity.auth.getSession();
  const claims = data.session ? decodeClaims(data.session.access_token) : null;
  if (!claims || isAdmin(claims)) return { title: m.mobile.loginTitle, amount: null, sub: m.mobile.loginBody };
  const w = await wallet(claims.sub);
  return { title: m.wallet.available, amount: formatIDR(w.idr.available, { locale }), sub: `${m.wallet.pending}: ${formatIDR(w.idr.pending, { locale })}` };
}

function BalanceWidget({ v }: { v: View }) {
  return (
    <FlexWidget clickAction="OPEN_URI" clickActionData={{ uri: 'clipper://wallet' }} accessibilityLabel={v.amount ? `${v.title} ${v.amount}` : v.title}
      style={{ height: 'match_parent', width: 'match_parent', backgroundColor: c.navy as `#${string}`, borderRadius: 18, padding: 16, justifyContent: 'center', flexGap: 4 }}>
      <TextWidget text={v.title} style={{ fontSize: 13, color: '#c7cede' }} maxLines={1} truncate="END" />
      {v.amount ? <TextWidget text={v.amount} style={{ fontSize: 26, fontWeight: '700', color: '#ffffff', adjustsFontSizeToFit: true }} maxLines={1} /> : null}
      <TextWidget text={v.sub} style={{ fontSize: 12, color: '#c7cede' }} maxLines={2} truncate="END" />
    </FlexWidget>
  );
}

const render = async () => <BalanceWidget v={await load().catch(() => ({ title: 'Clipper', amount: null, sub: '—' }))} />;

export const widgetTaskHandler: WidgetTaskHandler = async ({ widgetAction, renderWidget }) => {
  if (widgetAction === 'WIDGET_ADDED' || widgetAction === 'WIDGET_UPDATE' || widgetAction === 'WIDGET_RESIZED') renderWidget(await render());
};

export const refreshBalanceWidget = () => requestWidgetUpdate({ widgetName: 'Balance', renderWidget: render });
