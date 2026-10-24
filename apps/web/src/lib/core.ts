import { getImageProps } from 'next/image';
import { createCoreClient } from '@clipper/db-core';
import { coverUrl } from './cover';

// {domain} hanya membaca core sebagai anon (view publik + report_by_token), tanpa sesi.
export const core = createCoreClient();

/** Batas waktu query core: halaman publik tetap tampil (state error) kalau DB lambat, bukan menggantung. */
export const deadline = (ms = 4000) => AbortSignal.timeout(ms);

/** Cover lewat optimizer next/image (WebP, ukuran pas kartu) untuk komponen DS yang merender <img> sendiri. */
export function cardCoverSrc(path: string | null | undefined): string | null {
  const src = coverUrl(path);
  return src ? getImageProps({ src, alt: '', width: 384, height: 240 }).props.src : null;
}
