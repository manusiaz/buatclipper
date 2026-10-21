import { describe, expect, it } from 'vitest';
import { filtersToQuery, parseFilters, toRpcFilters } from './filters';

describe('campaign filters', () => {
  it('parses and sanitises query params', () => {
    const f = parseFilters({ q: '  #mpl ', platform: 'tiktok', category: 'games', status: 'ended', sort: 'rate' });
    expect(f).toEqual({ q: '#mpl', platform: 'tiktok', category: 'games', status: 'ended', sort: 'rate' });
    expect(parseFilters({ platform: 'myspace', status: 'x', sort: 'y', category: 'a b' })).toEqual({
      q: '',
      platform: '',
      category: '',
      status: 'active',
      sort: 'newest',
    });
  });
  it('round-trips through the query string', () => {
    const f = parseFilters({ q: 'kuasa', sort: 'deadline' });
    expect(filtersToQuery(f)).toBe('?q=kuasa&sort=deadline');
    expect(filtersToQuery(parseFilters({}))).toBe('');
  });
  it('maps to p_filters (default status = live+paused, ended = array)', () => {
    expect(toRpcFilters(parseFilters({}))).toEqual({ sort: 'newest', limit: 12 });
    expect(toRpcFilters(parseFilters({ status: 'ended', platform: 'youtube' }), 5)).toEqual({
      sort: 'newest',
      limit: 5,
      platform: 'youtube',
      status: ['tracking', 'exhausted', 'settling', 'settled'],
    });
    expect(toRpcFilters(parseFilters({ status: 'all' })).status).toBe('all');
  });
});
