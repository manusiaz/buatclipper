// Editor nilai config E-25: bentuk editor diturunkan dari tipe JSON nilai lama (update_config menolak tipe berbeda).
export type Json = string | number | boolean | null | Json[] | { [k: string]: Json };

export type EditorKind = 'boolean' | 'number' | 'string' | 'flags' | 'fields' | 'json';

const isObj = (v: unknown): v is Record<string, Json> => typeof v === 'object' && v !== null && !Array.isArray(v);

export function editorKind(v: Json): EditorKind {
  if (typeof v === 'boolean') return 'boolean';
  if (typeof v === 'number') return 'number';
  if (typeof v === 'string') return 'string';
  if (isObj(v) && Object.keys(v).length > 0) {
    const vals = Object.values(v);
    if (vals.every((x) => typeof x === 'boolean')) return 'flags';
    if (vals.every((x) => typeof x === 'string' || typeof x === 'number')) return 'fields';
  }
  return 'json';
}

/** Teks input → nilai bertipe sama dengan `like`; null = tidak valid. */
export function parseScalar(raw: string, like: Json): Json | undefined {
  if (typeof like === 'number') {
    const s = raw.trim().replace(',', '.');
    if (!/^-?\d+(\.\d+)?$/.test(s)) return undefined;
    return Number(s);
  }
  if (typeof like === 'string') return raw;
  return undefined;
}

export function parseJson(raw: string, like: Json): Json | undefined {
  try {
    const v = JSON.parse(raw) as Json;
    const type = (x: Json) => (Array.isArray(x) ? 'array' : x === null ? 'null' : typeof x);
    return type(v) === type(like) ? v : undefined;
  } catch {
    return undefined;
  }
}

/** Daftar perubahan path → [sebelum, sesudah] untuk konfirmasi diff. */
export function diff(before: Json, after: Json, path = ''): { path: string; before: Json | undefined; after: Json | undefined }[] {
  if (isObj(before) && isObj(after)) {
    const keys = [...new Set([...Object.keys(before), ...Object.keys(after)])];
    return keys.flatMap((k) => diff(before[k] as Json, after[k] as Json, path ? `${path}.${k}` : k));
  }
  return JSON.stringify(before) === JSON.stringify(after) ? [] : [{ path: path || '·', before, after }];
}
