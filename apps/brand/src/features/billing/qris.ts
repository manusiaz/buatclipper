// QRIS (EMVCo MPM): payload statis merchant → dinamis dengan nominal invoice. Tag 01 = 11 (statis) / 12 (dinamis),
// tag 54 = nominal, tag 63 = CRC16-CCITT (poly 0x1021, init 0xFFFF) atas seluruh payload sampai "6304".

export interface Tlv {
  id: string;
  value: string;
}

export function crc16(input: string): string {
  let crc = 0xffff;
  for (let i = 0; i < input.length; i++) {
    crc ^= input.charCodeAt(i) << 8;
    for (let b = 0; b < 8; b++) crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
  }
  return crc.toString(16).toUpperCase().padStart(4, '0');
}

/** Elemen tingkat atas; null kalau panjang tidak konsisten. */
export function parseTlv(payload: string): Tlv[] | null {
  const out: Tlv[] = [];
  let i = 0;
  while (i < payload.length) {
    const id = payload.slice(i, i + 2);
    const len = Number(payload.slice(i + 2, i + 4));
    if (!/^\d{2}$/.test(id) || !/^\d{2}$/.test(payload.slice(i + 2, i + 4)) || i + 4 + len > payload.length) return null;
    out.push({ id, value: payload.slice(i + 4, i + 4 + len) });
    i += 4 + len;
  }
  return out;
}

const tlv = ({ id, value }: Tlv) => `${id}${String(value.length).padStart(2, '0')}${value}`;

export function qrisAmount(amount: number): string | null {
  if (!Number.isFinite(amount) || amount <= 0) return null;
  const s = Number.isInteger(amount) ? String(amount) : amount.toFixed(2);
  return s.length <= 13 ? s : null;
}

/** Payload statis valid (CRC cocok) → payload dinamis untuk nominal itu; null kalau payload/nominal tidak valid. */
export function toDynamicQris(staticPayload: string, amount: number): string | null {
  const raw = staticPayload.trim();
  const value = qrisAmount(amount);
  const items = parseTlv(raw);
  if (!value || !items || items[0]?.id !== '00') return null;
  const crc = items.at(-1);
  if (crc?.id !== '63' || crc16(raw.slice(0, -4)) !== crc.value.toUpperCase()) return null;
  const body = items.filter((x) => x.id !== '63' && x.id !== '54').map((x) => (x.id === '01' ? { id: '01', value: '12' } : x));
  if (!body.some((x) => x.id === '01')) body.splice(1, 0, { id: '01', value: '12' });
  const at = body.findIndex((x) => Number(x.id) > 54);
  body.splice(at === -1 ? body.length : at, 0, { id: '54', value });
  const head = `${body.map(tlv).join('')}6304`;
  return head + crc16(head);
}
