'use client';

import type { ReactNode } from 'react';
import { CampaignBuilder, type BuilderContext, type CampaignDraft } from '@clipper/campaign-builder';
import { campaignUploadUrl, saveCampaign } from './actions';

const actions = { save: saveCampaign, uploadUrl: campaignUploadUrl };

/** Builder mode admin (F-A03). Simpan pertama membuat campaign → URL diganti ke ?campaign=<id> tanpa memuat ulang wizard. */
export function AdminBuilder({ context, initial, sidePanel }: { context: BuilderContext; initial: CampaignDraft | null; sidePanel?: ReactNode }) {
  return (
    <CampaignBuilder
      context={context}
      initial={initial}
      actions={actions}
      sidePanel={sidePanel}
      onSaved={(id) => {
        if (new URLSearchParams(window.location.search).get('campaign') !== id) {
          window.history.replaceState(null, '', `/campaigns/new?campaign=${id}`);
        }
      }}
    />
  );
}
