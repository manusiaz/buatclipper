// NIK (Nomor Induk Kependudukan) parsing for the 18+ check at KYC (§16, PP 40/2019 Pasal 31):
// 16 digits = 6 region + DDMMYY birth date + 4 serial. Women: DD + 40. The two-digit year is resolved to the most
// recent century that does not put the birth date in the future (relative to today in Asia/Jakarta), so "26" on
// 2026-10-19 means 2026 if the date has passed, else 1926. A person aged ≥ 100 whose NIK year collides with the
// current century is read as a newborn and rejected as under age; the reviewer resolves that from the KTP photo.
import { HttpError } from "./http.ts";

export interface Ymd {
  y: number;
  m: number;
  d: number;
}

export interface NikInfo {
  nik: string;
  birth: Ymd;
  female: boolean;
}

export const MIN_AGE = 18;

export function normalizeNik(input: string): string {
  const nik = String(input ?? "").replace(/[\s.-]/g, "");
  if (!/^\d{16}$/.test(nik)) throw new HttpError(422, "invalid_nik", "NIK harus 16 digit");
  return nik;
}

function isLeap(y: number): boolean {
  return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
}

function daysInMonth(y: number, m: number): number {
  return [31, isLeap(y) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1];
}

function cmp(a: Ymd, b: Ymd): number {
  return a.y - b.y || a.m - b.m || a.d - b.d;
}

/** Calendar date "today" in Asia/Jakarta (UTC+7, no DST). */
export function todayJakarta(now: Date = new Date()): Ymd {
  const t = new Date(now.getTime() + 7 * 3600 * 1000);
  return { y: t.getUTCFullYear(), m: t.getUTCMonth() + 1, d: t.getUTCDate() };
}

export function parseNik(input: string, today: Ymd = todayJakarta()): NikInfo {
  const nik = normalizeNik(input);
  if (nik.slice(0, 6) === "000000" || nik.slice(12) === "0000") {
    throw new HttpError(422, "invalid_nik", "NIK tidak valid");
  }
  let dd = Number(nik.slice(6, 8));
  const mm = Number(nik.slice(8, 10));
  const yy = Number(nik.slice(10, 12));
  const female = dd > 40;
  if (female) dd -= 40;
  if (mm < 1 || mm > 12 || dd < 1 || dd > 31) {
    throw new HttpError(422, "invalid_nik", "tanggal lahir di NIK tidak valid");
  }

  const century = Math.floor(today.y / 100) * 100;
  let y = century + yy;
  // Choose the latest year ≤ today. Validate the day against that year (29 Feb depends on the century).
  if (cmp({ y, m: mm, d: Math.min(dd, daysInMonth(y, mm)) }, today) > 0) y -= 100;
  if (dd > daysInMonth(y, mm)) throw new HttpError(422, "invalid_nik", "tanggal lahir di NIK tidak valid");
  return { nik, birth: { y, m: mm, d: dd }, female };
}

/** Completed years on `today`. Someone born 29 Feb turns a year older on 1 Mar in non-leap years. */
export function ageOn(birth: Ymd, today: Ymd): number {
  let age = today.y - birth.y;
  if (today.m < birth.m || (today.m === birth.m && today.d < birth.d)) age -= 1;
  return age;
}

/** Parses and enforces the minimum age; returns the normalized NIK info. */
export function assertAdultNik(input: string, today: Ymd = todayJakarta()): NikInfo {
  const info = parseNik(input, today);
  if (ageOn(info.birth, today) < MIN_AGE) {
    throw new HttpError(422, "under_age", "umur dari NIK belum 18 tahun");
  }
  return info;
}
