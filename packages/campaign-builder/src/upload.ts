import { UPLOAD_CACHE_CONTROL, UPLOAD_LIMITS } from './constants';
import type { AssetKind, UploadKind } from './types';

/*
 * Browser upload to a signed upload URL (api server action → storage createSignedUploadUrl). The browser has no Supabase
 * session (cookies are httpOnly), so the request replicates @supabase/storage-js 2.118 StorageFileApi.uploadToSignedUrl
 * for a File/Blob body exactly:
 *   PUT {signedUrl}   (= {storage}/object/upload/sign/{bucket}/{path}?token=…)
 *   headers: x-upsert: "false"   (+ the client's apikey header; no Authorization — the token in the URL authorizes)
 *   body: FormData { cacheControl: "3600", "": <file> }   (metadata field first: Storage reads it before the file stream;
 *         content-type multipart/form-data with boundary is set by fetch, the file part carries the file's MIME type)
 */

const EXT_MIME: Record<string, string> = {
  mp4: 'video/mp4',
  mov: 'video/quicktime',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  png: 'image/png',
  webp: 'image/webp',
  mp3: 'audio/mpeg',
  wav: 'audio/wav',
  pdf: 'application/pdf',
};

const MIME_ALIASES: Record<string, string> = {
  'image/jpg': 'image/jpeg',
  'image/pjpeg': 'image/jpeg',
  'audio/mp3': 'audio/mpeg',
  'audio/x-wav': 'audio/wav',
  'audio/wave': 'audio/wav',
  'audio/vnd.wave': 'audio/wav',
  'video/mov': 'video/quicktime',
};

/** Canonical MIME the bucket allow-list knows (browsers report wav/jpg/mp3 under several names, or nothing). */
export function normalizeMime(file: { name: string; type: string }): string {
  const type = (file.type || '').toLowerCase().split(';')[0]!.trim();
  if (type && MIME_ALIASES[type]) return MIME_ALIASES[type]!;
  if (type && type !== 'application/octet-stream') return type;
  const ext = file.name.toLowerCase().split('.').pop() ?? '';
  return EXT_MIME[ext] ?? type;
}

export type FileCheck = { ok: true; contentType: string } | { ok: false; reason: 'too_big' | 'bad_type'; maxBytes: number };

/** Bucket limits from config.toml: cover ≤ 2 MiB jpeg/png/webp; assets ≤ 500 MiB mp4/mov/jpg/png/webp/mp3/wav/pdf. */
export function checkFile(kind: UploadKind, file: { name: string; type: string; size: number }): FileCheck {
  const limit = UPLOAD_LIMITS[kind];
  const contentType = normalizeMime(file);
  if (!limit.mime.includes(contentType)) return { ok: false, reason: 'bad_type', maxBytes: limit.maxBytes };
  if (file.size > limit.maxBytes) return { ok: false, reason: 'too_big', maxBytes: limit.maxBytes };
  return { ok: true, contentType };
}

/** campaign_assets.kind of an uploaded file. */
export function assetKindForMime(mime: string): AssetKind {
  if (mime.startsWith('video/')) return 'video';
  if (mime.startsWith('image/')) return 'image';
  if (mime.startsWith('audio/')) return 'audio';
  return 'document';
}

export function acceptFor(kind: UploadKind): string {
  const exts = Object.entries(EXT_MIME)
    .filter(([, mime]) => UPLOAD_LIMITS[kind].mime.includes(mime))
    .map(([ext]) => `.${ext}`);
  return [...UPLOAD_LIMITS[kind].mime, ...exts].join(',');
}

export { formatBytes } from '@clipper/ui/format';

function publishableKey(): string | undefined {
  try {
    return process.env.NEXT_PUBLIC_CORE_PUBLISHABLE_KEY || undefined;
  } catch {
    return undefined;
  }
}

/** Builds the exact request storage-js sends; exported for tests. */
export function signedUploadRequest(file: Blob, contentType: string, apikey: string | undefined = publishableKey()): RequestInit {
  const typed = file.type === contentType ? file : new Blob([file], { type: contentType });
  const name = typeof File !== 'undefined' && file instanceof File ? file.name : 'upload';
  const body = new FormData();
  body.append('cacheControl', UPLOAD_CACHE_CONTROL);
  body.append('', typed, name);
  const headers: Record<string, string> = { 'x-upsert': 'false' };
  if (apikey) headers.apikey = apikey;
  return { method: 'PUT', headers, body };
}

export async function putToSignedUrl(
  signedUrl: string,
  file: Blob,
  contentType: string,
  fetchImpl: typeof fetch = fetch,
): Promise<{ ok: true } | { ok: false; error: string }> {
  try {
    const res = await fetchImpl(signedUrl, signedUploadRequest(file, contentType));
    if (res.ok) return { ok: true };
    let error = `http_${res.status}`;
    try {
      const body = (await res.json()) as { error?: string; message?: string };
      error = body.message || body.error || error;
    } catch {
      /* non-JSON error body */
    }
    return { ok: false, error };
  } catch {
    return { ok: false, error: 'network' };
  }
}

/** Public URL of a cover in the public bucket campaign-covers of the brand project (NEXT_PUBLIC_BRAND_DB_URL, same env as @clipper/db-brand). */
export function coverPublicUrl(path: string | null | undefined): string | null {
  if (!path) return null;
  let base: string | undefined;
  try {
    base = process.env.NEXT_PUBLIC_BRAND_DB_URL;
  } catch {
    base = undefined;
  }
  if (!base) return null;
  const encoded = path.split('/').map(encodeURIComponent).join('/');
  return `${base.replace(/\/+$/, '')}/storage/v1/object/public/${UPLOAD_LIMITS.cover.bucket}/${encoded}`;
}
