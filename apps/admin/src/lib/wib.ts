// <input type="datetime-local"> di admin selalu dibaca/ditulis sebagai WIB (UTC+7, tanpa DST), apa pun zona browser.
const WIB_MS = 7 * 3600 * 1000;

export function wibToIso(value: string | null | undefined): string | null {
  const m = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})(?::\d{2})?$/.exec((value ?? '').trim());
  if (!m) return null;
  const d = new Date(`${m[1]}T${m[2]}:00+07:00`);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

export function isoToWibInput(iso: string | null | undefined): string {
  if (!iso) return '';
  const t = new Date(iso).getTime();
  return Number.isNaN(t) ? '' : new Date(t + WIB_MS).toISOString().slice(0, 16);
}

/** Tanggal WIB (YYYY-MM-DD) dari ISO, untuk <input type="date">. */
export function isoToWibDate(iso: string | Date): string {
  return new Date(new Date(iso).getTime() + WIB_MS).toISOString().slice(0, 10);
}
