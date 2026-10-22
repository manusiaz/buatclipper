import type { UploadKind } from '@clipper/campaign-builder';

/** Batas bucket (db/brand/supabase/config.toml): cover ≤ 2 MiB, aset ≤ 500 MiB. */
export const MAX_BYTES: Record<UploadKind, number> = { cover: 2 * 1024 * 1024, asset: 500 * 1024 * 1024, internal: 500 * 1024 * 1024 };

/**
 * Path storage aset campaign (policy campaign_files_write + save_campaign): {org}/{campaign}/… ; berkas brief mentah di
 * {org}/{campaign}/internal/… (campaign_assets_internal_folder). Nama file disanitasi + awalan acak supaya tidak bentrok.
 */
export function assetPath(kind: UploadKind, orgId: string, campaignId: string, filename: string, rand: string): { bucket: string; path: string } {
  const dot = filename.lastIndexOf('.');
  const ext = dot > 0 ? filename.slice(dot + 1).toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 5) : '';
  const stem = (dot > 0 ? filename.slice(0, dot) : filename).replace(/[^A-Za-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'file';
  const name = `${kind === 'cover' ? 'cover-' : ''}${rand}-${stem}${ext ? `.${ext}` : ''}`;
  return {
    bucket: kind === 'cover' ? 'campaign-covers' : 'campaign-assets',
    path: `${orgId}/${campaignId}/${kind === 'internal' ? 'internal/' : ''}${name}`,
  };
}
