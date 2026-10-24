'use client';

import { useRouter } from 'next/navigation';
import { useCallback, useMemo, useState } from 'react';
import { useTranslations } from 'next-intl';
import { CampaignBuilder, type BuilderActions, type BuilderContext, type CampaignDraft } from '@clipper/campaign-builder';
import { toast } from '@clipper/ui';

/**
 * Builder brand. Draft baru yang tersimpan → URL ?campaign=<id> tanpa render server (replaceState). Render server berikutnya
 * (refresh, revalidasi) tidak me-remount builder selama campaign-nya sama; pindah campaign / draft baru → remount.
 */
export function BuilderHost({
  orgId,
  renderId,
  canBilling,
  context,
  initial,
  save,
  uploadUrl,
}: {
  orgId: string;
  renderId: string;
  /** Setelah diajukan: owner/finance → billing (B1.7); manajer tidak melihat invoice → dashboard campaign. */
  canBilling: boolean;
  context: BuilderContext;
  initial: CampaignDraft | null;
  save: BuilderActions['save'];
  uploadUrl: BuilderActions['uploadUrl'];
}) {
  const t = useTranslations('brand.builder');
  const router = useRouter();
  const [mount, setMount] = useState({ key: 0, render: renderId, current: initial?.id ?? null });
  if (renderId !== mount.render) {
    const incoming = initial?.id ?? null;
    setMount({ key: incoming === mount.current ? mount.key : mount.key + 1, render: renderId, current: incoming });
  }
  const actions = useMemo<BuilderActions>(() => ({ save, uploadUrl }), [save, uploadUrl]);
  const onSaved = useCallback(
    (id: string, submitted: boolean) => {
      setMount((m) => (m.current === id ? m : { ...m, current: id }));
      if (submitted) {
        toast.success(t('submitted'));
        router.push(canBilling ? `/${orgId}/billing` : `/${orgId}/campaigns/${id}`);
        return;
      }
      const url = new URL(window.location.href);
      if (url.searchParams.get('campaign') !== id) {
        url.searchParams.set('campaign', id);
        window.history.replaceState(null, '', url);
      }
    },
    [orgId, canBilling, router, t],
  );
  return <CampaignBuilder key={mount.key} context={context} initial={initial} actions={actions} onSaved={onSaved} />;
}
