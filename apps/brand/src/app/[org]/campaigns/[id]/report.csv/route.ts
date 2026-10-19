import { coreServer, getAuth } from '@clipper/auth/server';
import { toCsv } from '@/features/reports/csv';
import { isUuid } from '@/lib/org';

const PAGE = 1000;
const CHUNK = 100;

/** F-B09 export CSV submisi campaign (RLS: anggota org). Angka sosial dari snapshot terakhir tiap submisi. */
export async function GET(_req: Request, { params }: { params: Promise<{ org: string; id: string }> }) {
  const { org, id } = await params;
  const { claims } = await getAuth('sso');
  if (!claims) return new Response('unauthorized', { status: 401 });
  if (!isUuid(org) || !isUuid(id)) return new Response('not found', { status: 404 });
  const core = await coreServer();
  const { data: campaign } = await core.from('campaigns').select('id, org_id, slug').eq('id', id).maybeSingle();
  if (!campaign || campaign.org_id !== org) return new Response('not found', { status: 404 });

  const subs: { id: string | null; user_id: string | null; platform: string | null; url: string | null; posted_at: string | null; status: string | null; counted_views: number | null; last_snapshot_at: string | null; created_at: string | null }[] = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await core
      .from('submissions')
      .select('id, user_id, platform, url, posted_at, status, counted_views, last_snapshot_at, created_at')
      .eq('campaign_id', id)
      .order('created_at')
      .range(from, from + PAGE - 1);
    if (error) return new Response('error', { status: 500 });
    subs.push(...(data ?? []));
    if (!data || data.length < PAGE) break;
  }

  const userIds = [...new Set(subs.map((s) => s.user_id).filter((x): x is string => !!x))];
  const names = new Map<string, string>();
  const snaps = new Map<string, { views: number | null; likes: number | null; comments: number | null; shares: number | null }>();
  for (let i = 0; i < userIds.length; i += CHUNK) {
    const { data } = await core.from('profiles').select('id, username').in('id', userIds.slice(i, i + CHUNK));
    for (const p of data ?? []) if (p.id) names.set(p.id, p.username ?? '');
  }
  const withSnap = subs.filter((s) => s.id && s.last_snapshot_at);
  for (let i = 0; i < withSnap.length; i += CHUNK) {
    const part = withSnap.slice(i, i + CHUNK);
    const { data } = await core
      .from('view_snapshots')
      .select('submission_id, taken_at, views, likes, comments, shares')
      .in('submission_id', part.map((s) => s.id!))
      .in('taken_at', [...new Set(part.map((s) => s.last_snapshot_at!))]);
    const last = new Map(part.map((s) => [s.id!, new Date(s.last_snapshot_at!).getTime()]));
    for (const v of data ?? []) {
      if (v.submission_id && v.taken_at && last.get(v.submission_id) === new Date(v.taken_at).getTime()) snaps.set(v.submission_id, v);
    }
  }

  const csv = toCsv(
    ['submission_id', 'username', 'platform', 'url', 'posted_at', 'submitted_at', 'status', 'counted_views', 'views', 'likes', 'comments', 'shares', 'last_snapshot_at'],
    subs.map((s) => {
      const v = s.id ? snaps.get(s.id) : undefined;
      return [s.id, s.user_id ? names.get(s.user_id) : '', s.platform, s.url, s.posted_at, s.created_at, s.status, s.counted_views,
        v?.views, v?.likes, v?.comments, v?.shares, s.last_snapshot_at];
    }),
  );
  return new Response(`﻿${csv}`, {
    headers: {
      'content-type': 'text/csv; charset=utf-8',
      'content-disposition': `attachment; filename="campaign-${(campaign.slug ?? id).replace(/[^a-z0-9-]/g, '')}.csv"`,
      'cache-control': 'private, no-store',
    },
  });
}
