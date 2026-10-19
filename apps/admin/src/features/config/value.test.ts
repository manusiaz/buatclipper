import { describe, expect, it } from 'vitest';
import { diff, editorKind, parseJson, parseScalar } from './value';

describe('editorKind', () => {
  it('derives the editor from the JSON type', () => {
    expect(editorKind(true)).toBe('boolean');
    expect(editorKind(7)).toBe('number');
    expect(editorKind('')).toBe('string');
    expect(editorKind({ tiktok: true, x: false })).toBe('flags');
    expect(editorKind({ bank: '', number: '', name: '' })).toBe('fields');
    expect(editorKind([{ until_hours: 72 }])).toBe('json');
    expect(editorKind({})).toBe('json');
  });
});

describe('parsing keeps the type', () => {
  it('numbers', () => {
    expect(parseScalar('7', 1)).toBe(7);
    expect(parseScalar('0,5', 1)).toBe(0.5);
    expect(parseScalar('abc', 1)).toBeUndefined();
  });
  it('json must match the old type', () => {
    expect(parseJson('[1,2]', [])).toEqual([1, 2]);
    expect(parseJson('{"a":1}', [])).toBeUndefined();
    expect(parseJson('not json', {})).toBeUndefined();
  });
});

describe('diff', () => {
  it('lists changed paths only', () => {
    expect(diff({ a: 1, b: { c: true } }, { a: 1, b: { c: false } })).toEqual([{ path: 'b.c', before: true, after: false }]);
    expect(diff(5, 5)).toEqual([]);
    expect(diff([1], [1, 2])).toEqual([{ path: '·', before: [1], after: [1, 2] }]);
  });
});
