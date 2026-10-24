import { revalidatePath } from 'next/cache';
import type { FnResult } from '@clipper/auth/server';
import { dbError, type DbErrorLike } from './errors';

export type ActionResult<T = undefined> = { ok: true; data?: T } | { ok: false; error: string };

export const text = (fd: FormData, key: string): string => {
  const v = fd.get(key);
  return typeof v === 'string' ? v.trim() : '';
};

export const optText = (fd: FormData, key: string): string | null => text(fd, key) || null;

/** Hasil RPC → ActionResult + revalidasi halaman yang terdampak. */
export function settle(error: DbErrorLike, ...paths: string[]): ActionResult {
  if (error) return { ok: false, error: dbError(error) };
  paths.forEach((p) => revalidatePath(p));
  return { ok: true };
}

export function settleFn(r: FnResult<unknown>, ...paths: string[]): ActionResult {
  if (!r.ok) return { ok: false, error: r.error };
  paths.forEach((p) => revalidatePath(p));
  return { ok: true };
}
