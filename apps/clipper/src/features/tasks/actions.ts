'use server';

import { revalidatePath } from 'next/cache';
import { requireClipper } from '@clipper/auth/server';
import { isUuid } from '@clipper/clipper-lib/pure';
import { core, fail, ok, type Result } from '../lib/server';

/** F-C07: banding 1× per submisi yang ditolak (rejected → appealed). */
export async function appealSubmission(submissionId: string, message: string): Promise<Result> {
  await requireClipper();
  if (!isUuid(submissionId)) return fail('not_found:submission');
  const text = (message ?? '').trim();
  if (text.length < 1 || text.length > 1000) return fail('invalid:message');
  const db = await core();
  const { error } = await db.rpc('appeal_submission', { p_submission: submissionId, p_message: text });
  if (error) return fail(error.message);
  revalidatePath('/tasks');
  return ok(null);
}
