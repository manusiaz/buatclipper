import { hosts } from '@clipper/auth';
import { buildMyData } from '@/features/privacy/export';

/** POST /privacy/export → file JSON "Unduh data saya". Origin dicek karena cookie sesi berlaku di semua subdomain. */
export async function POST(request: Request) {
  if (request.headers.get('origin') !== new URL(hosts.accounts).origin) {
    return Response.json({ error: 'auth:forbidden' }, { status: 403 });
  }
  const r = await buildMyData();
  if (!r.ok) return Response.json({ error: r.error }, { status: r.status });
  const date = new Date().toISOString().slice(0, 10);
  return new Response(JSON.stringify(r.data, null, 2), {
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'content-disposition': `attachment; filename="clipper-data-${date}.json"`,
      'cache-control': 'no-store',
    },
  });
}
