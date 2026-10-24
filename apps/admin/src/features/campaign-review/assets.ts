import { brandServer } from '@clipper/auth/server';

export interface AssetRow {
  id: string | null;
  kind: string | null;
  storage_path: string | null;
  url: string | null;
  size_bytes?: number | null;
  audience?: string | null;
}

/** Aset campaign (storage brand) → URL yang bisa dibuka admin: link luar apa adanya, cover = URL publik, lainnya signed URL 10 menit. */
export async function assetHrefs(assets: AssetRow[]): Promise<Map<string, string>> {
  const db = await brandServer('admin');
  const out = new Map<string, string>();
  const signed: AssetRow[] = [];
  for (const a of assets) {
    if (!a.id) continue;
    if (a.url) out.set(a.id, a.url);
    else if (a.storage_path && a.kind === 'cover') out.set(a.id, db.storage.from('campaign-covers').getPublicUrl(a.storage_path).data.publicUrl);
    else if (a.storage_path) signed.push(a);
  }
  if (signed.length) {
    const { data } = await db.storage.from('campaign-assets').createSignedUrls(signed.map((a) => a.storage_path!), 600);
    data?.forEach((d, i) => {
      if (d.signedUrl) out.set(signed[i]!.id!, d.signedUrl);
    });
  }
  return out;
}

export const fileName = (a: AssetRow) => a.url ?? a.storage_path?.split('/').pop() ?? '—';
