// Langkah yang tetap di web (KYC & rekening = PII di accounts.{domain}; OAuth sosmed = halaman resmi platform, Google/
// Meta menolak WebView): dibuka di browser in-app DENGAN sesi app — kode handoff sekali pakai 60 detik dari identity
// (session-handoff) ditukar accounts.{domain}/handoff jadi cookie SSO, tanpa login ulang. `back` = alur yang
// kembali ke app (redirect ke clipper://…, auth session tertutup otomatis) → hasilnya dikembalikan sebagai URL.
import * as WebBrowser from 'expo-web-browser';
import { env } from './env';
import { invoke } from './supabase';

export const APP_SCHEME = 'clipper://';

export async function webUrl(host: 'app' | 'accounts', path: string): Promise<string> {
  const target = `${host === 'app' ? env.appUrl : env.accountsUrl}${path}`;
  const r = await invoke<{ code: string; url: string }>('identity', 'session-handoff', { action: 'create', next: target });
  // next = tujuan setelah login manual bila kode sudah kedaluwarsa / gagal ditukar.
  return r.ok && r.data?.url?.startsWith(`${env.accountsUrl}/handoff?`) ? `${r.data.url}&next=${encodeURIComponent(target)}` : target;
}

export async function openWeb(host: 'app' | 'accounts', path: string, opts: { back?: boolean } = {}): Promise<string | null> {
  const url = await webUrl(host, path);
  if (opts.back) {
    const r = await WebBrowser.openAuthSessionAsync(url, APP_SCHEME);
    return r.type === 'success' ? r.url : null;
  }
  await WebBrowser.openBrowserAsync(url, { presentationStyle: WebBrowser.WebBrowserPresentationStyle.PAGE_SHEET, controlsColor: '#1d5bff' });
  return null;
}
