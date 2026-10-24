import { appSiteAssociation } from '@clipper/clipper-lib/pure';

// App iOS native (apps/mobile): iOS memverifikasi app.{domain} ↔ Team ID + bundle lewat file ini (universal link).
export const dynamic = 'force-dynamic';

export function GET() {
  const aasa = appSiteAssociation(process.env.APPLE_TEAM_ID, process.env.IOS_BUNDLE_ID);
  return aasa ? Response.json(aasa) : new Response('Not found', { status: 404 });
}
