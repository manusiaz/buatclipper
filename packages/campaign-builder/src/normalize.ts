import { HASHTAG_RE, HTTPS_RE, MENTION_RE } from './constants';

/**
 * Client mirror of market.norm_list (api/_helpers.sql): hashtag/mention lowercase without #/@, links https
 * (no scheme → https://), text trimmed; empty and duplicate entries dropped. Values that the server would reject
 * with invalid:<field> are reported in `invalid` instead of being sent.
 */
export type ListKind = 'hashtag' | 'mention' | 'link' | 'text';

export interface NormalizedItem {
  value: string;
  ok: boolean;
}

const SCHEME_RE = /^[a-z][a-z0-9+.-]*:\/\//i;

export function normalizeHashtag(raw: string): NormalizedItem {
  const value = raw.trim().replace(/^#+/, '').toLowerCase();
  return { value, ok: value === '' || HASHTAG_RE.test(value) };
}

export function normalizeMention(raw: string): NormalizedItem {
  const value = raw.trim().replace(/^@+/, '').toLowerCase();
  return { value, ok: value === '' || MENTION_RE.test(value) };
}

/** "studio.id/promo" → "https://studio.id/promo"; "HTTPS://x" → "https://x"; "http://x" stays and is invalid. */
export function normalizeLink(raw: string): NormalizedItem {
  let value = raw.trim();
  if (value === '') return { value, ok: true };
  if (!SCHEME_RE.test(value)) value = `https://${value}`;
  value = value.replace(SCHEME_RE, (scheme) => scheme.toLowerCase());
  return { value, ok: HTTPS_RE.test(value) };
}

export function normalizeItem(kind: ListKind, raw: string): NormalizedItem {
  switch (kind) {
    case 'hashtag':
      return normalizeHashtag(raw);
    case 'mention':
      return normalizeMention(raw);
    case 'link':
      return normalizeLink(raw);
    default:
      return { value: raw.trim(), ok: true };
  }
}

export function normalizeList(kind: ListKind, items: readonly string[]): { values: string[]; invalid: string[] } {
  const values: string[] = [];
  const invalid: string[] = [];
  for (const raw of items) {
    const { value, ok } = normalizeItem(kind, raw);
    if (!ok) {
      invalid.push(raw);
      continue;
    }
    if (value !== '' && !values.includes(value)) values.push(value);
  }
  return { values, invalid };
}

/**
 * Splits pasted chip input. Tags/mentions split on commas and whitespace (a hashtag cannot contain spaces);
 * links split on commas and whitespace; free text (do/don't) splits on new lines only.
 */
export function splitChipInput(kind: ListKind, raw: string): string[] {
  const parts = kind === 'text' ? raw.split(/\r?\n/) : raw.split(/[\s,]+/);
  return parts.map((p) => p.trim()).filter(Boolean);
}

/** Display form of a stored value: "#mplid", "@studiosatu", link as-is. */
export function displayItem(kind: ListKind, value: string): string {
  if (kind === 'hashtag') return `#${value}`;
  if (kind === 'mention') return `@${value}`;
  return value;
}
