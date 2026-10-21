// Cloudflare Turnstile (CAPTCHA Auth identity, §15.6) di native: widget resmi di WebView ber-origin accounts.{domain}
// (hostname yang didaftarkan di dashboard Cloudflare). Tanpa site key = CAPTCHA mati di server juga, widget tidak tampil.
import { WebView } from 'react-native-webview';
import { env } from './env';

export const turnstileSiteKey = process.env.EXPO_PUBLIC_TURNSTILE_SITE_KEY || '';

const html = (key: string) => `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<script src="https://challenges.cloudflare.com/turnstile/v0/api.js?onload=go&render=explicit" async></script></head>
<body style="margin:0;display:flex;justify-content:center">
<div id="t"></div><script>function go(){turnstile.render('#t',{sitekey:${JSON.stringify(key)},
callback:function(t){window.ReactNativeWebView.postMessage(t)},'expired-callback':function(){window.ReactNativeWebView.postMessage('')}})}</script>
</body></html>`;

/** `round` berubah → widget dipasang ulang (token sekali pakai, sama dengan LoginForm web). */
export function Turnstile({ round, onToken }: { round: number; onToken: (t: string | undefined) => void }) {
  if (!turnstileSiteKey) return null;
  return (
    <WebView
      key={round}
      originWhitelist={['*']}
      source={{ html: html(turnstileSiteKey), baseUrl: env.accountsUrl }}
      onMessage={(e) => onToken(e.nativeEvent.data || undefined)}
      style={{ height: 70, backgroundColor: 'transparent' }}
      scrollEnabled={false}
    />
  );
}
