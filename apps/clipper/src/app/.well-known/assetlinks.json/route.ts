import { assetLinks } from '@/features/lib/pure';

// App Android (TWA dari PWA ini, Play Store): Chrome memverifikasi app.{domain} ↔ package + sertifikat lewat file ini.
export const dynamic = 'force-dynamic';

export function GET() {
  const links = assetLinks(process.env.ANDROID_APP_PACKAGE, process.env.ANDROID_CERT_SHA256);
  return links ? Response.json(links) : new Response('Not found', { status: 404 });
}
