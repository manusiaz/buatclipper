import { describe, expect, it } from 'vitest';
import { initialUsername, latestLegal, roleOf, USERNAME_RE, usernameCandidates } from './rules';

describe('roleOf', () => {
  const brand = 'https://brand.clipper.id';
  it('keeps an explicit role', () => expect(roleOf('brand', undefined, brand)).toBe('brand'));
  it('infers brand from next', () => expect(roleOf(undefined, 'https://brand.clipper.id/new', brand)).toBe('brand'));
  it('defaults to clipper', () => {
    expect(roleOf('admin', '/x', brand)).toBe('clipper');
    expect(roleOf(undefined, 'not a url', brand)).toBe('clipper');
  });
});

describe('initialUsername', () => {
  it('keeps a real existing username', () => expect(initialUsername('rani', 'x@y.z')).toBe('rani'));
  it('replaces generated member usernames with one from email', () => {
    expect(initialUsername('m_0123456789ab', 'Rani.Putri+promo@mail.com')).toBe('rani.putri');
  });
  it('returns empty when nothing usable', () => {
    expect(initialUsername(null, 'ab@x.id')).toBe('');
    expect(initialUsername(null, null)).toBe('');
  });
});

describe('usernameCandidates', () => {
  it('produces valid, unique suggestions', () => {
    const c = usernameCandidates('rani', () => 0.5);
    expect(c).toEqual(['rani550', 'rani_550', 'rani.id', 'rani_clips']);
    expect(c.every((x) => USERNAME_RE.test(x))).toBe(true);
  });
  it('stays within 30 chars', () => {
    expect(usernameCandidates('a'.repeat(30)).every((x) => x.length <= 30)).toBe(true);
  });
});

describe('latestLegal', () => {
  const now = new Date('2026-10-19T12:00:00Z');
  it('picks the newest published version per kind', () => {
    const rows = [
      { kind: 'privacy', version: '2026-01-01', url: 'https://x/p1', published_at: '2026-01-01T00:00:00Z' },
      { kind: 'privacy', version: '2026-10-01', url: 'https://x/p2', published_at: '2026-10-01T00:00:00Z' },
      { kind: 'privacy', version: '2026-12-01', url: 'https://x/p3', published_at: '2026-12-01T00:00:00Z' },
      { kind: 'tos_clipper', version: '2026-10-19', url: 'https://x/t', published_at: '2026-10-19T00:00:00Z' },
    ];
    expect(latestLegal(rows, now)).toEqual({
      privacy: { version: '2026-10-01', url: 'https://x/p2' },
      tos_clipper: { version: '2026-10-19', url: 'https://x/t' },
    });
  });
});
