// RFC 4180 CSV for finance/brand exports. Cells that a spreadsheet would treat as a formula (leading = + - @, tab,
// carriage return) are prefixed with "'" (OWASP CSV injection guidance). Lines end with CRLF.

const FORMULA_START = /^[=+\-@\t\r]/;

export function csvCell(value: unknown): string {
  if (value === null || value === undefined) return "";
  let s = typeof value === "string" ? value : String(value);
  if (FORMULA_START.test(s)) s = "'" + s;
  if (/[",\r\n]/.test(s)) s = '"' + s.replace(/"/g, '""') + '"';
  return s;
}

export function toCsv(header: readonly string[], rows: readonly (readonly unknown[])[]): string {
  const lines = [header.map(csvCell).join(",")];
  for (const r of rows) lines.push(r.map(csvCell).join(","));
  return lines.join("\r\n") + "\r\n";
}
