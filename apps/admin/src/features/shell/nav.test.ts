import { describe, expect, it } from 'vitest';
import { activeHref, allowed, navFor } from './nav';

const keys = (roles: string[]) => navFor(roles).map((n) => n.key);

describe('navFor', () => {
  it('super admin sees everything', () => {
    expect(keys(['admin_super'])).toHaveLength(12);
  });
  it('filters by role (§4)', () => {
    expect(keys(['admin_ops'])).toEqual(['overview', 'campaigns', 'builder', 'pinned', 'users', 'fulfillment', 'broadcast']);
    expect(keys(['admin_moderator'])).toEqual(['overview', 'review', 'fraud', 'users']);
    expect(keys(['admin_finance'])).toEqual(['overview', 'finance', 'fulfillment']);
    expect(keys(['admin_support'])).toEqual(['overview', 'users']);
    expect(keys(['admin_finance', 'admin_moderator'])).toContain('fraud');
  });
  it('non-admin sees nothing', () => {
    expect(keys([])).toEqual([]);
    expect(allowed(['clipper'], [])).toBe(false);
  });
});

describe('activeHref', () => {
  const hrefs = ['/', '/campaigns', '/campaigns/new', '/users'];
  it('longest prefix wins, root only exact', () => {
    expect(activeHref('/', hrefs)).toBe('/');
    expect(activeHref('/campaigns', hrefs)).toBe('/campaigns');
    expect(activeHref('/campaigns/new', hrefs)).toBe('/campaigns/new');
    expect(activeHref('/users/x', hrefs)).toBe('/users');
    expect(activeHref('/campaignsx', hrefs)).toBeNull();
  });
});
