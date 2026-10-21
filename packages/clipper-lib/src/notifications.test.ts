import { describe, expect, it } from 'vitest';
import { createTranslator } from 'next-intl';
import id from '@clipper/i18n/messages/id/notifications';
import en from '@clipper/i18n/messages/en/notifications';
import { amountRefs, budgetLevel, EVENTS, notificationHref } from './notifications';

const links = { brand: 'https://brand.x', accounts: 'https://accounts.x' };
const C = '11111111-2222-4333-8444-555555555555';
const get = (o: unknown, path: string) => path.split('.').reduce<unknown>((x, k) => (x as Record<string, unknown>)?.[k], o);

describe('notification messages', () => {
  const values = {
    campaign: 'K', platform: 'TikTok', handle: '', amount: 'Rp1', expiresAt: 'x', until: 'x', count: '2', invoice: 'INV',
    dueAt: 'x', reward: 'R', title: 'T', body: 'B', org: 'O', agency: 'A', client: 'C', level: 'p80', decision: 'overturned',
    cause: 'fraud', scope: 'submission',
  };
  for (const [loc, msgs] of [['id', id], ['en', en]] as const) {
    it(`${loc}: every event has a title and body that format`, () => {
      const t = createTranslator({ locale: loc, messages: { n: msgs } as Record<string, unknown>, namespace: 'n', onError: (e) => { throw e; } }) as unknown as (k: string, v: Record<string, string>) => string;
      for (const e of EVENTS) {
        for (const part of ['title', 'body']) {
          expect(typeof get(msgs, `${e}.${part}`), `${loc} ${e}.${part}`).toBe('string');
          expect(t(`${e}.${part}`, values)).not.toContain('{');
        }
      }
    });
  }
});

describe('notificationHref', () => {
  it('clipper events stay in app, brand/kyc go to their hosts', () => {
    expect(notificationHref('claim.expiring', { campaign_id: C }, links)).toBe(`/campaigns/${C}`);
    expect(notificationHref('campaign.new', { campaign_id: '../x' }, links)).toBe('/campaigns');
    expect(notificationHref('fulfillment.delivered', {}, links)).toBe('/wallet?tab=reward');
    expect(notificationHref('kyc.rejected', {}, links)).toBe('https://accounts.x/kyc');
    expect(notificationHref('invoice.issued', { org_id: 'o1' }, links)).toBe('https://brand.x/o1/billing');
    expect(notificationHref('managed.draft_ready', { org_id: 'o1', campaign_id: C }, links)).toBe(
      `https://brand.x/o1/campaigns/new?campaign=${C}`,
    );
    expect(notificationHref('broadcast.sent', {}, links)).toBeNull();
  });
  it('payload helpers', () => {
    expect(budgetLevel(100)).toBe('full');
    expect(budgetLevel('80')).toBe('p80');
    expect(budgetLevel(undefined)).toBe('p50');
    expect(amountRefs({ amounts: [{ amount: 1 }, null] })).toEqual([{ amount: 1 }]);
    expect(amountRefs({ amount: 5, reward_type: 'IDR' })).toHaveLength(1);
    expect(amountRefs({})).toEqual([]);
  });
});
