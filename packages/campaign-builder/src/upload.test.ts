import { describe, expect, it, vi } from 'vitest';
import { acceptFor, assetKindForMime, checkFile, normalizeMime, putToSignedUrl, signedUploadRequest } from './upload';

const MIB = 1024 * 1024;

describe('bucket limits (config.toml)', () => {
  it('cover: ≤ 2 MiB jpeg/png/webp', () => {
    expect(checkFile('cover', { name: 'c.webp', type: 'image/webp', size: 2 * MIB })).toEqual({ ok: true, contentType: 'image/webp' });
    expect(checkFile('cover', { name: 'c.webp', type: 'image/webp', size: 2 * MIB + 1 })).toMatchObject({ ok: false, reason: 'too_big' });
    expect(checkFile('cover', { name: 'c.gif', type: 'image/gif', size: 10 })).toMatchObject({ ok: false, reason: 'bad_type' });
    expect(checkFile('cover', { name: 'c.mp4', type: 'video/mp4', size: 10 })).toMatchObject({ ok: false, reason: 'bad_type' });
  });

  it('assets / internal: ≤ 500 MiB mp4/mov/jpg/png/webp/mp3/wav/pdf', () => {
    expect(checkFile('asset', { name: 'raw.mov', type: 'video/quicktime', size: 500 * MIB })).toEqual({ ok: true, contentType: 'video/quicktime' });
    expect(checkFile('asset', { name: 'raw.mov', type: 'video/quicktime', size: 500 * MIB + 1 })).toMatchObject({ ok: false, reason: 'too_big' });
    expect(checkFile('internal', { name: 'brief.docx', type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', size: 10 })).toMatchObject({
      ok: false,
      reason: 'bad_type',
    });
    expect(checkFile('internal', { name: 'brief.pdf', type: 'application/pdf', size: 10 })).toEqual({ ok: true, contentType: 'application/pdf' });
  });

  it('normalizes MIME aliases and empty types by extension', () => {
    expect(normalizeMime({ name: 'a.wav', type: 'audio/x-wav' })).toBe('audio/wav');
    expect(normalizeMime({ name: 'a.mp3', type: '' })).toBe('audio/mpeg');
    expect(normalizeMime({ name: 'a.JPG', type: 'application/octet-stream' })).toBe('image/jpeg');
    expect(normalizeMime({ name: 'a.jpg', type: 'image/jpg' })).toBe('image/jpeg');
  });

  it('asset kind by MIME, accept attribute', () => {
    expect(assetKindForMime('video/mp4')).toBe('video');
    expect(assetKindForMime('image/png')).toBe('image');
    expect(assetKindForMime('audio/wav')).toBe('audio');
    expect(assetKindForMime('application/pdf')).toBe('document');
    expect(acceptFor('cover')).toContain('.webp');
    expect(acceptFor('cover')).not.toContain('.mp4');
  });
});

describe('signed upload request (replica of storage-js uploadToSignedUrl for a File)', () => {
  it('PUT, x-upsert false, multipart body {cacheControl: 3600, "": file}', async () => {
    const file = new File(['abc'], 'clip.wav', { type: 'audio/x-wav' });
    const req = signedUploadRequest(file, 'audio/wav', 'sb_publishable_x');
    expect(req.method).toBe('PUT');
    expect(req.headers).toEqual({ 'x-upsert': 'false', apikey: 'sb_publishable_x' });
    const body = req.body as FormData;
    const entries = [...body.entries()];
    expect(entries.map(([k]) => k)).toEqual(['cacheControl', '']);
    expect(entries[0]![1]).toBe('3600');
    const part = entries[1]![1] as File;
    expect(part.name).toBe('clip.wav');
    expect(part.type).toBe('audio/wav');
    expect(await part.text()).toBe('abc');
    expect(signedUploadRequest(file, 'audio/wav', '').headers).toEqual({ 'x-upsert': 'false' });  // undefined = default env key
  });

  it('putToSignedUrl reports http and network errors', async () => {
    const file = new File(['x'], 'a.pdf', { type: 'application/pdf' });
    const ok = vi.fn(async () => new Response('{}', { status: 200 }));
    expect(await putToSignedUrl('https://core/storage/v1/object/upload/sign/campaign-assets/a.pdf?token=t', file, 'application/pdf', ok)).toEqual({ ok: true });
    expect(ok).toHaveBeenCalledWith('https://core/storage/v1/object/upload/sign/campaign-assets/a.pdf?token=t', expect.objectContaining({ method: 'PUT' }));
    const denied = vi.fn(async () => new Response(JSON.stringify({ error: 'Unauthorized', message: 'invalid signature' }), { status: 400 }));
    expect(await putToSignedUrl('https://x', file, 'application/pdf', denied)).toEqual({ ok: false, error: 'invalid signature' });
    const offline = vi.fn(async () => {
      throw new TypeError('fetch failed');
    });
    expect(await putToSignedUrl('https://x', file, 'application/pdf', offline)).toEqual({ ok: false, error: 'network' });
  });
});
