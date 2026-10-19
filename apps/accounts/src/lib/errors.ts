import { parseDbError } from '@clipper/i18n';

// Kode Edge Function identity yang artinya sama dengan kode bersama.
const ALIAS: Record<string, string> = { unauthorized: 'auth:no_session', invalid_token: 'auth:no_session' };

/** Kode mesin (Edge Function / RPC) → kunci pesan yang dicoba berurutan: namespace accounts, lalu errors bersama. */
export function errorKeys(code: string | null | undefined): { keys: string[]; param: string } {
  const { key, param } = parseDbError(ALIAS[code ?? ''] ?? code);
  return { keys: [`accounts.errors.${key}`, `errors.${key}`, 'errors.generic'], param };
}

const MACHINE = /^[a-z_]+(:[^\s]*)?$/;

/** Error PostgREST → kode mesin. Fungsi api core mengirim kode di message (market.fail); selain itu dari SQLSTATE. */
export function dbCode(e: { code?: string; message?: string } | null | undefined, bySqlState: Record<string, string> = {}): string {
  if (!e) return 'generic';
  if (e.code && bySqlState[e.code]) return bySqlState[e.code]!;
  if (e.message && MACHINE.test(e.message)) return e.message;
  if (e.code === '42501') return 'auth:no_session';
  return 'generic';
}
