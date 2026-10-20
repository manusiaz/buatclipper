export const MAX_BANK_LINES = 5000; // batas api.import_bank_lines per unggahan

export interface BankLine {
  date: string; // YYYY-MM-DD
  amount: number; // + kredit, − debit
  reference: string;
  description: string;
}

const COLS = {
  date: /^(tanggal|tgl|date|tanggal transaksi|value date|tanggal valuta)$/,
  amount: /^(nominal|amount|jumlah|mutasi)$/,
  credit: /^(kredit|credit|cr)$/,
  debit: /^(debit|db|dr)$/,
  reference: /^(referensi|ref|reference|no\.? ?ref(erensi)?|nomor referensi)$/,
  description: /^(keterangan|deskripsi|description|uraian)$/,
};

/** Satu baris CSV → sel (tanda kutip ganda, pemisah koma/titik koma/tab). */
function cells(line: string, sep: string): string[] {
  const out: string[] = [];
  let cur = '';
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]!;
    if (quoted) {
      if (ch === '"' && line[i + 1] === '"') (cur += '"'), i++;
      else if (ch === '"') quoted = false;
      else cur += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === sep) out.push(cur.trim()), (cur = '');
    else cur += ch;
  }
  out.push(cur.trim());
  return out;
}

/** "1.500.000,00" / "1,500,000.00" / "-6500" / "(6.500)" → angka; selain itu null. */
export function bankAmount(raw: string): number | null {
  let s = raw.replace(/\s|Rp|IDR/gi, '');
  let sign = 1;
  if (/^\(.*\)$/.test(s)) (sign = -1), (s = s.slice(1, -1));
  if (s.startsWith('-')) (sign = -sign), (s = s.slice(1));
  if (!/^[\d.,]+$/.test(s)) return null;
  const dot = s.lastIndexOf('.');
  const comma = s.lastIndexOf(',');
  let dec = '';
  if (dot >= 0 && comma >= 0) dec = dot > comma ? '.' : ',';
  else if (comma >= 0) dec = /,\d{1,2}$/.test(s) ? ',' : '';
  else if (dot >= 0) dec = /^\d{1,3}(\.\d{3})+$/.test(s) ? '' : '.';
  const [int, frac = ''] = dec ? [s.slice(0, s.lastIndexOf(dec)), s.slice(s.lastIndexOf(dec) + 1)] : [s, ''];
  const n = Number(`${int.replace(/[.,]/g, '')}.${frac || '0'}`);
  return Number.isFinite(n) && /^\d+$/.test(int.replace(/[.,]/g, '')) ? sign * n : null;
}

/** YYYY-MM-DD, DD/MM/YYYY, DD-MM-YYYY → YYYY-MM-DD (tanggal kalender valid), selain itu null. */
export function bankDate(raw: string): string | null {
  const iso = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw);
  const dmy = /^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/.exec(raw);
  const [y, m, d] = iso ? [iso[1], iso[2], iso[3]] : dmy ? [dmy[3], dmy[2]!.padStart(2, '0'), dmy[1]!.padStart(2, '0')] : [];
  if (!y) return null;
  const v = `${y}-${m}-${d}`;
  return new Date(`${v}T00:00:00Z`).toISOString().startsWith(v) ? v : null;
}

/**
 * CSV mutasi internet banking → baris rekonsiliasi (A3.5). Baris judul wajib: tanggal, nominal bertanda (atau kolom debit &
 * kredit), referensi; keterangan opsional. Baris yang tidak terbaca dilaporkan nomornya (1 = baris judul), bukan dilewati.
 */
export function parseBankCsv(text: string): { lines: BankLine[]; badRows: number[] } {
  const rows = text.replace(/^﻿/, '').split(/\r?\n/);
  const sep = [';', '\t', ','].find((c) => (rows[0] ?? '').includes(c)) ?? ',';
  const head = cells(rows[0] ?? '', sep).map((h) => h.toLowerCase().replace(/\s+/g, ' '));
  const idx = (re: RegExp) => head.findIndex((h) => re.test(h));
  const at = { date: idx(COLS.date), amount: idx(COLS.amount), credit: idx(COLS.credit), debit: idx(COLS.debit), reference: idx(COLS.reference), description: idx(COLS.description) };
  if (at.date < 0 || at.reference < 0 || (at.amount < 0 && (at.credit < 0 || at.debit < 0))) return { lines: [], badRows: [1] };
  const lines: BankLine[] = [];
  const badRows: number[] = [];
  rows.forEach((row, i) => {
    if (i === 0 || !row.trim()) return;
    const c = cells(row, sep);
    const date = bankDate(c[at.date] ?? '');
    const reference = (c[at.reference] ?? '').slice(0, 120);
    let amount: number | null;
    if (at.amount >= 0) amount = bankAmount(c[at.amount] ?? '');
    else {
      const cr = c[at.credit] ? bankAmount(c[at.credit]!) : 0;
      const db = c[at.debit] ? bankAmount(c[at.debit]!) : 0;
      amount = cr === null || db === null ? null : (cr ?? 0) - Math.abs(db ?? 0);
    }
    if (!date || !reference || amount === null || amount === 0) badRows.push(i + 1);
    else lines.push({ date, amount, reference, description: (at.description >= 0 ? c[at.description] ?? '' : '').slice(0, 500) });
  });
  return { lines, badRows };
}
