/** Kode voucher dari textarea (dipisah baris, spasi, koma, titik koma) atau CSV (kolom pertama; header "code" dilewati). */
export function parseCodes(text: string, csv = false): string[] {
  const lines = text.split(/\r?\n/);
  const raw = csv
    ? lines.map((l) => (l.split(/[,;\t]/)[0] ?? '').trim().replace(/^"(.*)"$/, '$1').replace(/""/g, '"'))
    : text.split(/[\s,;]+/);
  const out = raw.map((c) => c.trim()).filter((c) => c && !(csv && /^(code|kode)$/i.test(c)));
  return [...new Set(out)];
}
