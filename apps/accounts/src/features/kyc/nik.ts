// Cek NIK di browser untuk petunjuk umur sebelum kirim. Salinan aturan db/identity/supabase/functions/_shared/nik.ts;
// keputusan tetap di member-data (server).
export interface Ymd {
  y: number;
  m: number;
  d: number;
}

export const MIN_AGE = 18;

export type NikCheck =
  | { ok: true; birth: Ymd; age: number }
  | { ok: false; error: 'invalid_nik' }
  | { ok: false; error: 'under_age'; birth: Ymd; age: number };

export function todayJakarta(now: Date = new Date()): Ymd {
  const t = new Date(now.getTime() + 7 * 3600 * 1000);
  return { y: t.getUTCFullYear(), m: t.getUTCMonth() + 1, d: t.getUTCDate() };
}

const isLeap = (y: number) => (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
const daysIn = (y: number, m: number) => [31, isLeap(y) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]!;
const cmp = (a: Ymd, b: Ymd) => a.y - b.y || a.m - b.m || a.d - b.d;

export function ageOn(birth: Ymd, today: Ymd): number {
  return today.y - birth.y - (today.m < birth.m || (today.m === birth.m && today.d < birth.d) ? 1 : 0);
}

export const cleanNik = (s: string) => s.replace(/\D/g, '').slice(0, 16);

/** Digit 7–12 = DDMMYY (perempuan DD + 40); tahun dua digit = abad terakhir yang tidak melewati hari ini. */
export function checkNik(input: string, today: Ymd = todayJakarta()): NikCheck {
  const nik = input.replace(/[\s.-]/g, '');
  if (!/^\d{16}$/.test(nik) || nik.slice(0, 6) === '000000' || nik.slice(12) === '0000') return { ok: false, error: 'invalid_nik' };
  let d = Number(nik.slice(6, 8));
  const m = Number(nik.slice(8, 10));
  if (d > 40) d -= 40;
  if (m < 1 || m > 12 || d < 1 || d > 31) return { ok: false, error: 'invalid_nik' };
  let y = Math.floor(today.y / 100) * 100 + Number(nik.slice(10, 12));
  if (cmp({ y, m, d: Math.min(d, daysIn(y, m)) }, today) > 0) y -= 100;
  if (d > daysIn(y, m)) return { ok: false, error: 'invalid_nik' };
  const birth = { y, m, d };
  const age = ageOn(birth, today);
  return age < MIN_AGE ? { ok: false, error: 'under_age', birth, age } : { ok: true, birth, age };
}
