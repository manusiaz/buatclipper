// Upload dari browser lewat signed upload URL (sesi httpOnly → tidak ada client Supabase di browser). Body meniru
// storage-js uploadToSignedUrl: PUT multipart {cacheControl, file} + header x-upsert.

export const IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/webp'];
export const extOf = (type: string) => (type === 'image/png' ? 'png' : type === 'image/webp' ? 'webp' : 'jpg');

/**
 * Foto kamera HP sering > batas bucket atau HEIC: kecilkan & ubah ke JPEG di canvas. File yang sudah sesuai dikirim apa adanya.
 * Gagal decode (format tidak dikenal browser) → error 'file_type'.
 */
export async function fitImage(file: File, maxBytes: number, maxSide = 2400): Promise<Blob> {
  if (IMAGE_TYPES.includes(file.type) && file.size <= maxBytes) return file;
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch {
    throw new Error('file_type');
  }
  const scale = Math.min(1, maxSide / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext('2d')?.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  for (const quality of [0.85, 0.7, 0.55]) {
    const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, 'image/jpeg', quality));
    if (blob && blob.size <= maxBytes) return blob;
  }
  throw new Error('file_too_large');
}

export async function putSigned(signedUrl: string, file: Blob, apikey: string): Promise<void> {
  const body = new FormData();
  body.append('cacheControl', '3600');
  body.append('', file);
  const res = await fetch(signedUrl, { method: 'PUT', body, headers: { 'x-upsert': 'false', apikey } });
  if (!res.ok) throw new Error('upload_failed');
}
