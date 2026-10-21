// Langkah sekali jalan yang tetap di web (KYC, rekening, hubungkan sosmed via OAuth resmi platform, onboarding):
// dibuka di browser sistem — Google/Meta menolak OAuth di WebView, dan data PII hanya diproses accounts.{domain}.
import * as WebBrowser from 'expo-web-browser';
import { env } from './env';

export async function openWeb(host: 'app' | 'accounts', path: string): Promise<void> {
  const base = host === 'app' ? env.appUrl : env.accountsUrl;
  await WebBrowser.openBrowserAsync(`${base}${path}`, { presentationStyle: WebBrowser.WebBrowserPresentationStyle.PAGE_SHEET });
}
