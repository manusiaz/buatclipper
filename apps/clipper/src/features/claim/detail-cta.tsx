'use client';

// CTA detail campaign (F-C05/F-C06), menempel di atas nav bawah: Ambil Campaign → Submit video + hitung mundur claim.
// State tertutup tidak tampil seperti tombol; not_eligible selalu membawa aksi perbaikan.
import { useState, useTransition } from 'react';
import Link from 'next/link';
import { useLocale, useTranslations } from 'next-intl';
import { Alert, Button, Countdown, Icon, toast } from '@clipper/ui';
import { claimCampaign } from './actions';
import { fixFor } from '../campaigns/fix';
import { SubmitSheet, type SubmitAccount } from '../submit/submit-sheet';

export interface DetailCtaProps {
  campaignId: string;
  state: string | null;
  reasonText: string | null;
  reason: string | null;
  claim: { id: string; expires_at: string } | null;
  accounts: SubmitAccount[];
  autoSubmit?: boolean;
}

export function DetailCta({ campaignId, state, reasonText, reason, claim, accounts, autoSubmit }: DetailCtaProps) {
  const t = useTranslations('clipper');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [open, setOpen] = useState(state === 'claimed_not_submitted' && !!autoSubmit);
  const [error, setError] = useState<{ message: string; code: string } | null>(null);
  const [pending, start] = useTransition();

  const claimNow = () =>
    start(async () => {
      setError(null);
      const r = await claimCampaign(campaignId);
      if (!r.ok) {
        setError({ message: r.message, code: r.code });
        return;
      }
      toast.success(t('claim.success'), { description: t('claim.successBody') });
    });

  const errFix = error ? fixFor(error.code, campaignId) : null;
  const fix = state === 'not_eligible' ? fixFor(reason, campaignId) : null;

  let body;
  if (state === 'can_claim') {
    body = (
      <Button fullWidth size="lg" iconRight="arrow_forward" loading={pending} loadingText={t('claim.claiming')} onClick={claimNow}>
        {t('claim.cta')}
      </Button>
    );
  } else if (state === 'claimed_not_submitted' && claim) {
    body = (
      <div className="flex flex-col gap-1.5">
        <Button fullWidth size="lg" variant="ink" iconLeft="upload" onClick={() => setOpen(true)}>
          {t('claim.submit')}
        </Button>
        <p className="flex items-center justify-center gap-1 text-caption text-muted">
          {t('claim.expiresIn')}
          <Countdown target={claim.expires_at} locale={locale} withIcon expiredLabel={t('claim.expired')} className="text-ink" />
        </p>
      </div>
    );
  } else {
    const icon = state === 'slots_full' ? 'groups' : state === 'budget_exhausted' ? 'local_fire_department' : state === 'deadline_passed' ? 'schedule' : 'lock';
    body = (
      <div className="flex flex-col gap-1.5" role="group" aria-label={t(`cta.${state ?? 'not_eligible'}`)}>
        <div
          aria-disabled="true"
          className="flex h-12 items-center justify-center gap-2 rounded-control border-[1.5px] border-dashed border-border-hover bg-surface text-sm font-bold text-text-2"
        >
          <Icon name={icon} size={18} />
          {t(`cta.${state ?? 'not_eligible'}`)}
        </div>
        {reasonText || fix ? (
          <p className="flex flex-wrap items-center justify-center gap-x-1.5 text-center text-caption text-muted">
            {reasonText ? <span>{reasonText}</span> : null}
            {fix ? (
              <Button href={fix.href} linkAs={Link} variant="link" size="sm" iconRight="arrow_forward" className="text-caption font-bold">
                {t(`fix.${fix.key}`)}
              </Button>
            ) : null}
          </p>
        ) : null}
      </div>
    );
  }

  return (
    <>
      <div className="h-28" aria-hidden />
      <div className="fixed inset-x-0 bottom-[calc(68px+var(--safe-bottom))] z-20 mx-auto w-full max-w-[560px] px-4 pb-2 md:bottom-[92px]">
        <div className="surface-glass flex flex-col gap-2 rounded-card p-2 shadow-pop">
          {error ? (
            <Alert tone="danger" action={errFix ? { label: t(`fix.${errFix.key}`), href: errFix.href, linkAs: Link } : undefined}>
              {error.message}
            </Alert>
          ) : null}
          {body}
        </div>
      </div>
      {claim ? (
        <SubmitSheet open={open} onOpenChange={setOpen} campaignId={campaignId} claimId={claim.id} accounts={accounts} />
      ) : null}
    </>
  );
}
