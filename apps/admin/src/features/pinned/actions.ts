'use server';

import { coreServer, requireAdmin } from '@clipper/auth/server';
import { settle, text, type ActionResult } from '@/lib/action';
import { wibToIso } from '@/lib/wib';
import { validBanners, type Banner } from './banners';

async function config(key: string, value: unknown): Promise<ActionResult> {
  await requireAdmin('admin_ops');
  const db = await coreServer('admin');
  const { error } = await db.rpc('update_config', { p_key: key, p_value: value as never });
  return settle(error, '/pinned');
}

/** E-06 pinned_rank/pinned_until lewat update_config campaign.pin (rank kosong + until kosong = lepas pin). */
export async function pinCampaign(campaignId: string | null, fd: FormData): Promise<ActionResult> {
  const rank = text(fd, 'rank');
  return config('campaign.pin', {
    campaign_id: campaignId ?? text(fd, 'campaign_id'),
    rank: rank ? Number(rank) : null,
    until: wibToIso(text(fd, 'until')),
  });
}

export async function unpinCampaign(campaignId: string): Promise<ActionResult> {
  return config('campaign.pin', { campaign_id: campaignId, rank: null, until: null });
}

/** E-32 kategori (categories.upsert); tidak ada hapus — nonaktifkan. */
export async function upsertCategory(id: string | null, fd: FormData): Promise<ActionResult> {
  const sort = text(fd, 'sort');
  return config('categories.upsert', {
    id: id ?? text(fd, 'id').toLowerCase(),
    name_id: text(fd, 'name_id'),
    name_en: text(fd, 'name_en'),
    ...(sort ? { sort: Number(sort) } : {}),
    active: fd.get('active') != null,
  });
}

/** E-25 public.home.banners (admin_ops boleh). */
export async function saveBanners(banners: Banner[]): Promise<ActionResult> {
  const clean = validBanners(banners);
  if (!clean) return { ok: false, error: 'invalid:banner' };
  return config('public.home.banners', clean);
}
