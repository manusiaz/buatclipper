// Error dari Data API / Edge Function → kode mesin untuk UI (dipetakan ke namespace errors / admin.errors di client).
// Fungsi api core memakai message = kode (kepala db/core/supabase/schemas/api/_helpers.sql); fungsi identity memakai teks
// bebas, jadi dipetakan dari SQLSTATE.
export type DbErrorLike = { message?: string | null; code?: string | null } | null | undefined;

const MACHINE = /^[a-z_]+(?::[^\s]+)?$/;

export function dbError(e: DbErrorLike): string {
  const msg = (e?.message ?? '').trim();
  if (MACHINE.test(msg)) return msg;
  if (msg.includes('two_person')) return 'two_person';
  if (/fetch failed|network/i.test(msg)) return 'network';
  switch (e?.code) {
    case '42501':
      return 'auth:forbidden';
    case 'P0002':
      return 'not_found';
    case '23505':
      return 'duplicate';
    case '23514':
      return 'constraint';
    case '22023':
    case '22P02':
      return 'invalid_input';
    case 'PGRST301':
    case 'PGRST303':
      return 'auth:no_session';
    default:
      return 'generic';
  }
}
