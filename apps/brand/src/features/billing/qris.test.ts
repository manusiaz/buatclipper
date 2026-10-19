import { describe, expect, it } from 'vitest';
import { crc16, parseTlv, qrisAmount, toDynamicQris } from './qris';

const el = (id: string, v: string) => `${id}${String(v.length).padStart(2, '0')}${v}`;
const sign = (body: string) => `${body}6304${crc16(`${body}6304`)}`;
const STATIC = sign(
  el('00', '01') +
    el('01', '11') +
    el('26', el('00', 'ID.CO.QRIS.WWW') + el('01', '936000140000000001') + el('02', '000000000001') + el('03', 'UMI')) +
    el('52', '5812') +
    el('53', '360') +
    el('58', 'ID') +
    el('59', 'PT CLIPPER') +
    el('60', 'JAKARTA'),
);

describe('crc16', () => {
  it('matches the CRC-16/CCITT-FALSE check value', () => {
    expect(crc16('123456789')).toBe('29B1');
  });
});

describe('toDynamicQris', () => {
  it('switches to dynamic, inserts tag 54 after 53 and re-signs', () => {
    const out = toDynamicQris(STATIC, 1_250_000)!;
    const items = parseTlv(out)!;
    expect(items.map((x) => x.id)).toEqual(['00', '01', '26', '52', '53', '54', '58', '59', '60', '63']);
    expect(items.find((x) => x.id === '01')!.value).toBe('12');
    expect(items.find((x) => x.id === '54')!.value).toBe('1250000');
    expect(crc16(out.slice(0, -4))).toBe(out.slice(-4));
  });
  it('replaces an existing amount and keeps decimals', () => {
    const once = toDynamicQris(STATIC, 1000)!;
    const twice = toDynamicQris(once, 2500.5)!;
    expect(parseTlv(twice)!.filter((x) => x.id === '54')).toEqual([{ id: '54', value: '2500.50' }]);
  });
  it('rejects broken payloads and amounts', () => {
    expect(toDynamicQris('', 1000)).toBeNull();
    expect(toDynamicQris(`${STATIC.slice(0, -4)}0000`, 1000)).toBeNull();
    expect(toDynamicQris(STATIC.slice(0, 20), 1000)).toBeNull();
    expect(toDynamicQris(STATIC, 0)).toBeNull();
    expect(qrisAmount(1e14)).toBeNull();
  });
});
