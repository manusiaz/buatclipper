'use server';

import { revalidatePath } from 'next/cache';
import { invokeFunction, requireClipper } from '@clipper/auth/server';
import { httpsUrl, isUuid, safeThumb } from '@clipper/clipper-lib/pure';
import { fail, ok, type Result } from '../lib/server';

export interface VideoItem {
  postId: string;
  url: string;
  caption: string;
  postedAt: string;
  durationSec: number | null;
  thumbnail: string | null;
  missingTags: string[];
}

type RawVideo = Omit<VideoItem, 'missingTags'> & { missing_tags: string[] | null };

/** C1.8: video akun terhubung yang diposting setelah claim + tag wajib yang kurang (Edge Function creator/social). */
export async function listVideos(accountId: string, claimId: string): Promise<Result<VideoItem[]>> {
  await requireClipper();
  if (!isUuid(accountId) || !isUuid(claimId)) return fail('bad_request');
  const r = await invokeFunction<{ platform: string; videos: RawVideo[] }>('creator', 'social', {
    action: 'list_videos',
    account_id: accountId,
    claim_id: claimId,
  });
  if (!r.ok) return fail(r.error, r.detail);
  return ok(
    (r.data.videos ?? []).slice(0, 60).map((v) => ({
      postId: String(v.postId),
      url: httpsUrl(v.url) ?? '',
      caption: String(v.caption ?? ''),
      postedAt: String(v.postedAt ?? ''),
      durationSec: typeof v.durationSec === 'number' ? v.durationSec : null,
      thumbnail: safeThumb(v.thumbnail),
      missingTags: Array.isArray(v.missing_tags) ? v.missing_tags.map(String) : [],
    })),
  );
}

/** Submit video (pilih dari daftar atau tempel URL). Semua kode gagal dipetakan ke pesan sendiri. */
export async function submitVideo(input: {
  campaignId: string;
  claimId: string;
  accountId: string;
  postId?: string;
  url?: string;
}): Promise<Result<{ status: string }>> {
  await requireClipper();
  const { campaignId, claimId, accountId } = input;
  if (!isUuid(campaignId) || !isUuid(claimId) || !isUuid(accountId)) return fail('bad_request');
  const postId = input.postId?.trim().slice(0, 64);
  const url = input.url ? httpsUrl(input.url.trim()) : null;
  if (!postId && !url) return fail('bad_url');
  const r = await invokeFunction<{ submission_id: string; status: string }>('creator', 'social', {
    action: 'submit',
    claim_id: claimId,
    account_id: accountId,
    ...(postId ? { post_id: postId } : { url }),
  });
  if (!r.ok) return fail(r.error, r.detail);
  revalidatePath('/tasks');
  revalidatePath(`/campaigns/${campaignId}`);
  revalidatePath('/campaigns');
  return ok({ status: r.data.status });
}
