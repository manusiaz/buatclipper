import { describe, expect, it } from 'vitest';
import { isBrandEvent, notificationHref, notificationValues } from './events';

const org = '11111111-1111-4111-8111-111111111111';
const camp = '22222222-2222-4222-8222-222222222222';
const inv = '33333333-3333-4333-8333-333333333333';

describe('notificationHref', () => {
  it('routes invoice events to the invoice detail', () => {
    expect(notificationHref('invoice.issued', { org_id: org, invoice_id: inv })).toBe(`/${org}/billing?invoice=${inv}`);
  });
  it('routes campaign events to the dashboard or builder', () => {
    expect(notificationHref('budget.used', { org_id: org, campaign_id: camp })).toBe(`/${org}/campaigns/${camp}`);
    expect(notificationHref('managed.draft_ready', { org_id: org, campaign_id: camp })).toBe(`/${org}/campaigns/new?campaign=${camp}`);
  });
  it('agency approval opens the client org', () => {
    expect(notificationHref('agency.link_approved', { org_id: org, client_org_id: camp })).toBe(`/${camp}/campaigns`);
  });
  it('returns null without an org id', () => {
    expect(notificationHref('org.verified', {})).toBeNull();
    expect(notificationHref('org.verified', { org_id: '../admin' })).toBeNull();
  });
});

describe('notificationValues', () => {
  const idr = (n: number) => `Rp${n}`;
  it('fills every key', () => {
    const v = notificationValues({}, idr);
    expect(Object.values(v).every((x) => x === '')).toBe(true);
  });
  it('formats IDR and non-cash amounts', () => {
    expect(notificationValues({ total: 1000 }, idr).amount).toBe('Rp1000');
    expect(notificationValues({ amount: 8, reward_type: 'DIAMOND', unit_label: 'Diamonds' }, idr).amount).toBe('8 Diamonds');
    expect(notificationValues({ number: 'INV-1' }, idr).number).toBe('INV-1');
  });
  it('knows brand events', () => {
    expect(isBrandEvent('campaign.live')).toBe(true);
    expect(isBrandEvent('payout.paid')).toBe(false);
  });
});
