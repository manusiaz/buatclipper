'use server';

import { revalidatePath } from 'next/cache';
import { refreshSession } from '@clipper/auth/actions';
import { getAuth, invokeFunction } from '@clipper/auth/server';
import { extOf, IMAGE_TYPES } from '@/lib/upload';

type Result<T = object> = ({ ok: true } & T) | { ok: false; error: string };

/** Signed upload URL foto KTP: bucket identity kyc-docs, folder milik user (<uid>/<uuid>.<ext>, policy storage). */
export async function kycUploadUrl(type: string): Promise<Result<{ path: string; signedUrl: string }>> {
  if (!IMAGE_TYPES.includes(type)) return { ok: false, error: 'file_type' };
  const { supabase, claims } = await getAuth('sso');
  if (!claims) return { ok: false, error: 'auth:no_session' };
  const path = `${claims.sub}/${crypto.randomUUID()}.${extOf(type)}`;
  const { data, error } = await supabase.storage.from('kyc-docs').createSignedUploadUrl(path);
  if (error || !data) return { ok: false, error: 'upload_failed' };
  return { ok: true, path: data.path, signedUrl: data.signedUrl };
}

/** C1.12: member-data cek umur dari NIK, HMAC (unik) + enkripsi, consent kyc; lalu claim kyc diperbarui. */
export async function submitKyc(input: { legalName: string; nik: string; docPath: string }): Promise<Result> {
  const r = await invokeFunction('identity', 'member-data', {
    action: 'submit_kyc',
    legal_name: input.legalName,
    nik: input.nik,
    doc_path: input.docPath,
  });
  if (!r.ok) return { ok: false, error: r.error };
  await refreshSession('sso');
  revalidatePath('/', 'layout');
  return { ok: true };
}
