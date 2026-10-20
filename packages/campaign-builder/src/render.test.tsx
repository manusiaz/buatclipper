import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { ReactNode } from 'react';
import { renderToString } from 'react-dom/server';
import { NextIntlClientProvider } from 'next-intl';
import { describe, expect, it } from 'vitest';
import { CampaignBuilder } from './builder';
import { draftFromDetail } from './detail';
import { costSummary } from './cost';
import { useBuilderT, useUiLocale } from './i18n';
import { BasicsStep } from './steps/basics';
import { BriefStep } from './steps/brief';
import { BudgetStep } from './steps/budget';
import { EligibilityStep } from './steps/eligibility';
import { PlatformsStep } from './steps/platforms';
import { RewardsStep } from './steps/rewards';
import { ScheduleStep } from './steps/schedule';
import type { StepProps } from './steps/shared';
import { SummaryStep } from './steps/summary';
import { CAMPAIGN, ORG, RT_DM, ctx, validDraft } from './test-fixtures';
import type { BuilderActions, CampaignDraft } from './types';

const load = (locale: 'id' | 'en') =>
  JSON.parse(readFileSync(fileURLToPath(new URL(`../../i18n/messages/${locale}/builder.json`, import.meta.url)), 'utf8')) as Record<string, unknown>;

function html(node: ReactNode, locale: 'id' | 'en' = 'id'): string {
  return renderToString(
    <NextIntlClientProvider
      locale={locale}
      timeZone="Asia/Jakarta"
      messages={{ builder: load(locale) }}
      onError={(e) => {
        throw e;
      }}
    >
      {node}
    </NextIntlClientProvider>,
  );
}

const actions: BuilderActions = {
  save: async () => ({ ok: true, id: CAMPAIGN }),
  uploadUrl: async () => ({ ok: false, error: 'not in tests' }),
};

/** Steps rendered without the builder shell, with the real next-intl translator (missing keys throw). */
function Host({ draft, children }: { draft: CampaignDraft; children: (p: StepProps) => ReactNode }) {
  const props: StepProps = {
    draft,
    update: () => {},
    ctx,
    locked: false,
    t: useBuilderT(),
    locale: useUiLocale(),
    errorOf: () => undefined,
    upload: async () => null,
    uploading: {},
    goTo: () => {},
  };
  return <>{children(props)}</>;
}

const rich = validDraft({
  id: CAMPAIGN,
  service_mode: 'managed',
  required_hashtags: ['mplid'],
  dos: ['Pakai subtitle'],
  faq: [{ q: 'Boleh musik?', a: 'Bebas lisensi' }],
  pools: [
    { key: 'idr', id: null, reward_type_id: ctx.rewardTypes[0]!.id, total: 10_000_000, max_per_clip: 1_000_000 },
    { key: 'dm', id: null, reward_type_id: RT_DM, total: 50_000, max_per_clip: 2000 },
  ],
  rules: [
    { key: 'a', kind: 'per_1k_views', pool: 'idr', platform: 'tiktok', params: { rate: 2000 } },
    { key: 'b', kind: 'per_1k_views', pool: 'idr', platform: 'instagram', params: { rate: 2500 } },
    { key: 'c', kind: 'tiered_cpm', pool: 'dm', platform: null, params: { tiers: [{ from: 0, to: 50_000, rate: 8 }, { from: 50_000, to: null, rate: 6 }] } },
    { key: 'd', kind: 'milestone_bonus', pool: 'dm', platform: null, params: { threshold: 100_000, amount: 500 } },
    { key: 'e', kind: 'flat_per_post', pool: 'dm', platform: 'tiktok', params: { amount: 10 } },
  ],
  assets: [{ key: 'l', id: null, kind: 'link', audience: 'clipper', storage_path: null, url: 'https://drive.example/f', size_bytes: null, name: 'drive.example' }],
  internal_files: [{ key: 'i', id: null, kind: 'document', audience: 'internal', storage_path: `${ORG}/${CAMPAIGN}/internal/brief.pdf`, url: null, size_bytes: 2048, name: 'brief.pdf' }],
});

describe('render smoke test (SSR, every message resolves)', () => {
  it('full builder: brand new campaign (step 1), id + en', () => {
    for (const locale of ['id', 'en'] as const) {
      const out = html(<CampaignBuilder context={ctx} actions={actions} />, locale);
      expect(out).toContain(locale === 'id' ? 'Nama campaign' : 'Campaign name');
      expect(out).toContain('aria-current="step"');
    }
  });

  it('full builder: admin mode with side panel, unverified org', () => {
    const out = html(
      <CampaignBuilder
        context={{ ...ctx, mode: 'admin', org: { ...ctx.org, status: 'pending_verification' }, feeRules: [{ id: 'g', scope: 'global', mgmt_fee_pct: 15, admin_fee_pct: 5 }] }}
        initial={rich}
        actions={actions}
        sidePanel={<p>RAW BRIEF</p>}
      />,
    );
    expect(out).toContain('RAW BRIEF');
    expect(out).toContain('Builder tim');
  });

  it('full builder: submitted campaign opens on the summary, locked, no submit button', () => {
    const out = html(<CampaignBuilder context={ctx} initial={{ ...rich, status: 'in_review' }} actions={actions} />);
    expect(out).toContain('brief terkunci');
    expect(out).toContain('Ringkasan biaya');
    expect(out).not.toContain('>Ajukan<');
  });

  it('every step renders with a rich draft (managed, multi-reward, all rule kinds)', () => {
    const steps = [BasicsStep, BriefStep, PlatformsStep, RewardsStep, BudgetStep, EligibilityStep, ScheduleStep];
    for (const locale of ['id', 'en'] as const) {
      for (const Step of steps) {
        const out = html(<Host draft={rich}>{(p) => <Step {...p} />}</Host>, locale);
        expect(out.length).toBeGreaterThan(100);
      }
    }
    const summary = html(
      <Host draft={rich}>
        {(p) => <SummaryStep {...p} cost={costSummary(rich, ctx)} issues={[]} effectiveFee={ctx.fee} submit={<button type="button">submit</button>} />}
      </Host>,
    );
    expect(summary).toContain('Ringkasan biaya');
    expect(summary).toContain('Rp17.770.000'); // regresi AB-3: 10 jt Rupiah ditagih + 4,5 jt fee (atas 22,5 jt nilai) + 2,5 jt managed + 770 rb pajak; Diamonds tidak ditagih
  });

  it('builder renders a draft loaded from api.campaign_detail', () => {
    const d = draftFromDetail({ campaign: { id: CAMPAIGN, org_id: ORG, title: 'Dari detail', status: 'rejected', platforms: ['tiktok'] } });
    const out = html(<CampaignBuilder context={ctx} initial={d} actions={actions} />);
    expect(out).toContain('Dari detail');
    expect(out).toContain('ditolak');
  });
});
