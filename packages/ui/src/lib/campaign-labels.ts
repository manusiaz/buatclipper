// Label kartu campaign (id/en) + tipe state CTA — data murni untuk CampaignCard web & kartu app native.
/** CTA per user from api.list_campaigns (F-C03). */
export type CampaignCtaState = 'can_claim' | 'claimed_not_submitted' | 'slots_full' | 'budget_exhausted' | 'deadline_passed' | 'not_eligible';

export interface CampaignCardLabels {
  pinned: string;
  isNew: string;
  perViews: string;
  viewsLeft: (compact: string) => string;
  example: (views: string, earning: string) => string;
  creators: (n: string) => string;
  deadlinePrefix: string;
  budgetUsed: string;
  cta: Record<CampaignCtaState, string>;
  claimExpires: string;
}

export const CARD_LABELS_ID: CampaignCardLabels = {
  pinned: 'Pinned',
  isNew: 'Baru',
  perViews: '/1K views',
  viewsLeft: (c) => `± ${c} views lagi`,
  example: (v, e) => `${v} views = ${e}`,
  creators: (n) => `${n} kreator`,
  deadlinePrefix: 'Berakhir',
  budgetUsed: 'Budget terpakai',
  cta: {
    can_claim: 'Ambil Campaign',
    claimed_not_submitted: 'Kirim Video',
    slots_full: 'Slot penuh',
    budget_exhausted: 'Budget habis',
    deadline_passed: 'Deadline lewat',
    not_eligible: 'Belum memenuhi syarat',
  },
  claimExpires: 'Sisa waktu',
};

export const CARD_LABELS_EN: CampaignCardLabels = {
  pinned: 'Pinned',
  isNew: 'New',
  perViews: '/1K views',
  viewsLeft: (c) => `± ${c} views left`,
  example: (v, e) => `${v} views = ${e}`,
  creators: (n) => `${n} creators`,
  deadlinePrefix: 'Ends',
  budgetUsed: 'Budget used',
  cta: {
    can_claim: 'Claim campaign',
    claimed_not_submitted: 'Submit video',
    slots_full: 'Slots full',
    budget_exhausted: 'Budget used up',
    deadline_passed: 'Deadline passed',
    not_eligible: 'Not eligible yet',
  },
  claimExpires: 'Time left',
};

export const cardLabels = (locale: 'id' | 'en' = 'id'): CampaignCardLabels => (locale === 'en' ? CARD_LABELS_EN : CARD_LABELS_ID);
