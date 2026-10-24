import type { SaveResult } from './types';

/** Keys of the builder payload owned by the admin project (schedule = lifecycle, money); the rest is brand content. */
export const ADMIN_KEYS = ['start_at', 'submit_deadline', 'view_window_days', 'pools', 'rules', 'fee_rule'] as const;

/** Split toSavePayload into api.save_campaign of the brand project (content + assets) and of the admin project. */
export function splitSavePayload(payload: Record<string, unknown>): { content: Record<string, unknown>; economics: Record<string, unknown> } {
  const content: Record<string, unknown> = {};
  const economics: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(payload)) ((ADMIN_KEYS as readonly string[]).includes(k) ? economics : content)[k] = v;
  return { content, economics };
}

type RpcError = { message: string; details?: string | null } | null;
// Client Data API brand & admin (supabase-js); rpc generik per database, jadi dipanggil lewat bentuk minimal ini.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type RpcClient = { rpc: (fn: any, args?: any) => PromiseLike<{ data: unknown; error: RpcError }> };
export type PersistClients = { brand: RpcClient; core: RpcClient };

const RETRY = ['retry:replica_lag'];
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Call an admin RPC that waits for the brand replica (retry:replica_lag) — up to ~10 s. */
export async function untilReplicated<T, E extends RpcError>(call: () => PromiseLike<{ data: T; error: E }>, wait = sleep): Promise<{ data: T; error: E }> {
  let r = await call();
  for (let i = 0; i < 20 && r.error && RETRY.includes(r.error.message); i++) {
    await wait(500);
    r = await call();
  }
  return r;
}

const failed = (error: RpcError): SaveResult => ({ ok: false, error: error?.message || 'generic', detail: error?.details || undefined });

/**
 * Builder save across both projects: content first (brand, returns content_version), then admin with that version — always,
 * also without economics keys, so the call returns only after the admin replica holds this content (read-your-writes for the
 * builder page, campaign_detail of admin). Submit validates exactly the content version the builder saw.
 */
export async function persistCampaign(
  { brand, core }: PersistClients,
  payload: Record<string, unknown>,
  submit: boolean,
  wait = sleep,
): Promise<SaveResult> {
  const { content, economics } = splitSavePayload(payload);
  const b = await brand.rpc('save_campaign', { p_campaign: content });
  const saved = b.data as { id?: string; content_version?: number } | null;
  if (b.error || !saved?.id) return failed(b.error);
  const a = await untilReplicated(
    () => core.rpc('save_campaign', { p_campaign: { id: saved.id, content_version: saved.content_version, ...economics }, p_submit: submit }),
    wait,
  );
  if (a.error) return failed(a.error);
  return { ok: true, id: saved.id };
}
