import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { safeNext } from '@clipper/auth';
import { requireAccount } from '@clipper/auth/server';
import { Alert, Button, Card, EmptyState, PageHeader, StatusBadge, formatDateTime } from '@clipper/ui';
import { KycForm } from '@/features/kyc/kyc-form';
import { identityDb } from '@/lib/identity';
import { supportUrl } from '@/lib/support';
import { one, withParams, type SearchParams } from '@/lib/url';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('accounts.meta'))('kyc') };
}

export default async function KycPage({ searchParams }: { searchParams: SearchParams }) {
  await requireAccount();
  const next = one((await searchParams).next);
  const [t, id, support] = await Promise.all([getTranslations('accounts.kyc'), identityDb(), supportUrl()]);
  const { data: kyc, error } = await id
    .from('my_kyc')
    .select('legal_name, nik_last4, status, reject_reason, submitted_at, decided_at')
    .maybeSingle();
  if (error) throw new Error(error.message);
  const status = kyc?.status ?? 'none';

  const back = next ? (
    <Button href={safeNext(next)} variant="secondary" iconLeft="arrow_back">
      {t('back')}
    </Button>
  ) : null;
  const toPayout = (
    <Button href={withParams('/payout-methods', { next })} linkAs={Link} iconRight="arrow_forward">
      {t('toPayout')}
    </Button>
  );

  return (
    <div className="flex flex-col gap-5">
      <PageHeader
        title={t('title')}
        description={t('description')}
        meta={<StatusBadge kind="kyc" status={status} label={t(`status.${status}`)} />}
      />

      {status === 'pending' || status === 'approved' ? (
        <Card>
          <EmptyState
            icon={status === 'pending' ? 'hourglass_top' : 'verified'}
            tone={status === 'pending' ? 'warn' : 'success'}
            title={status === 'pending' ? t('pendingTitle') : t('approvedTitle')}
            body={status === 'pending' ? t('pendingBody') : t('approvedBody')}
          >
            <dl className="mt-1 grid w-full max-w-sm grid-cols-[auto_1fr] gap-x-4 gap-y-1.5 rounded-card-sm bg-surface-2 p-4 text-left text-body-s">
              <dt className="text-muted">{t('legalName')}</dt>
              <dd className="min-w-0 font-semibold break-words text-ink">{kyc?.legal_name}</dd>
              <dt className="text-muted">{t('nik')}</dt>
              <dd className="font-semibold text-ink tnum">•••• {kyc?.nik_last4}</dd>
              {kyc?.submitted_at && (
                <>
                  <dt className="text-muted">{t('submittedAt')}</dt>
                  <dd className="text-ink">{formatDateTime(kyc.submitted_at)}</dd>
                </>
              )}
            </dl>
            <div className="mt-3 flex flex-wrap justify-center gap-2">
              {back}
              {toPayout}
            </div>
          </EmptyState>
        </Card>
      ) : (
        <>
          {status === 'rejected' && (
            <Alert
              tone="danger"
              title={t('rejectedTitle')}
              action={support ? { label: t('contactSupport'), href: support } : undefined}
            >
              {t('rejectedBody', { reason: kyc?.reject_reason || t('noReason') })}
            </Alert>
          )}
          <Card padding="lg" className="max-w-2xl">
            <KycForm defaultName={kyc?.legal_name ?? ''} />
          </Card>
          {back && <div>{back}</div>}
        </>
      )}
    </div>
  );
}
