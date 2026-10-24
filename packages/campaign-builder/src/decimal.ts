/**
 * Minimal exact decimal arithmetic (BigInt, value = v / 10^s) so the cost summary reproduces Postgres numeric
 * results of finance.issue_invoice exactly (round(x, 2) = half away from zero), without floating-point drift.
 */
export interface Dec {
  v: bigint;
  s: number;
}

const POW10: bigint[] = [];
function pow10(n: number): bigint {
  if (POW10[n] === undefined) POW10[n] = 10n ** BigInt(n);
  return POW10[n]!;
}

const NUM_RE = /^(-)?(\d+)(?:\.(\d*))?(?:e([+-]?\d+))?$/i;

/** Parses a JS number (via its shortest round-trip text, which is what JSON sends to Postgres) or a decimal string. */
export function dec(x: number | string | bigint): Dec {
  if (typeof x === 'bigint') return { v: x, s: 0 };
  const text = typeof x === 'number' ? (Number.isFinite(x) ? String(x) : '0') : x.trim();
  const m = NUM_RE.exec(text);
  if (!m) return { v: 0n, s: 0 };
  const neg = m[1] === '-';
  const intPart = m[2] ?? '0';
  const frac = m[3] ?? '';
  const exp = m[4] ? Number(m[4]) : 0;
  let v = BigInt(intPart + frac);
  let s = frac.length - exp;
  if (s < 0) {
    v *= pow10(-s);
    s = 0;
  }
  return { v: neg ? -v : v, s };
}

function align(a: Dec, b: Dec): [bigint, bigint, number] {
  if (a.s === b.s) return [a.v, b.v, a.s];
  if (a.s > b.s) return [a.v, b.v * pow10(a.s - b.s), a.s];
  return [a.v * pow10(b.s - a.s), b.v, b.s];
}

export function add(...xs: Dec[]): Dec {
  return xs.reduce<Dec>((acc, x) => {
    const [p, q, s] = align(acc, x);
    return { v: p + q, s };
  }, { v: 0n, s: 0 });
}

export function mul(a: Dec, b: Dec): Dec {
  return { v: a.v * b.v, s: a.s + b.s };
}

/** a / 10^k (exact). */
export function shift(a: Dec, k: number): Dec {
  return { v: a.v, s: a.s + k };
}

/** Postgres round(numeric, scale): half away from zero. */
export function round(a: Dec, scale: number): Dec {
  if (a.s <= scale) return a;
  const d = pow10(a.s - scale);
  const neg = a.v < 0n;
  const abs = neg ? -a.v : a.v;
  let q = abs / d;
  if ((abs % d) * 2n >= d) q += 1n;
  return { v: neg ? -q : q, s: scale };
}

export function toNumber(a: Dec): number {
  if (a.s === 0) return Number(a.v);
  const neg = a.v < 0n;
  const abs = (neg ? -a.v : a.v).toString().padStart(a.s + 1, '0');
  const text = `${neg ? '-' : ''}${abs.slice(0, abs.length - a.s)}.${abs.slice(abs.length - a.s)}`;
  return Number(text);
}

export function isPositive(a: Dec): boolean {
  return a.v > 0n;
}
