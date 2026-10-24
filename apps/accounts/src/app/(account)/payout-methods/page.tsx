import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { safeNext } from '@clipper/auth';
import { coreServer, requireAccount } from '@clipper/auth/server';
import { Alert, Badge, Button, Card, CardDescription, CardHeader, CardTitle, EmptyState, Icon, PageHeader } from '@clipper/ui';
import { AddMethodForm } from '@/features/payout-methods/add-method-form';
import { RecipientForm } from '@/features/payout-methods/recipient-form';
import { bankName, piiFields } from '@/features/payout-methods/rules';
import { identityDb } from '@/lib/identity';
import { one, UUID_RE, withParams, type SearchParams } from '@/lib/url';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('accounts.meta'))('payoutMethods') };
}

export default async function PayoutMethodsPage({ searchParams }: { searchParams: SearchParams }) {
  await requireAccount();
  const sp = await searchParams;
  const next = one(sp.next);
  const rewardType = one(sp.reward_type);
  const [t, id] = await Promise.all([getTranslations('accounts'), identityDb()]);
  const [methods, kyc, share, reward] = await Promise.all([
    id.rpc('my_payout_methods'),
    id.from('my_kyc').select('legal_name, status').maybeSingle(),
    id.from('my_consents').select('kind').eq('kind', 'share_with_brand').is('revoked_at', null).limit(1),
    rewardType && UUID_RE.test(rewardType)
      ? coreServer().then((core) => core.from('reward_types').select('id, name, recipient_schema').eq('id', rewardType).maybeSingle())
      : null,
  ]);
  if (methods.error) throw new Error(methods.error.message);
  if (kyc.error) throw new Error(kyc.error.message);

  const list = methods.data ?? [];
  const kycOk = !!kyc.data && kyc.data.status !== 'rejected';
  const fields = reward?.data ? piiFields(reward.data.recipient_schema) : [];
  const here = withParams('/payout-methods', { next, reward_type: rewardType });

  const recipient = rewardType ? (
    <Card padding="lg">
      <CardHeader>
        <CardTitle>{t('recipient.title', { reward: reward?.data?.name ?? '—' })}</CardTitle>
        <CardDescription>{t('recipient.description')}</CardDescription>
      </CardHeader>
      {!reward?.data ? (
        <Alert tone="danger">{t('recipient.notFound')}</Alert>
      ) : fields.length === 0 ? (
        <EmptyState compact icon="check_circle" tone="success" title={t('recipient.noneNeeded')} />
      ) : (
        <RecipientForm rewardTypeId={reward.data.id!} fields={fields} shareActive={!!share.data?.length} next={next} />
      )}
    </Card>
  ) : null;

  return (
    <div className="flex flex-col gap-5">
      <PageHeader
        title={t('payout.title')}
        description={t('payout.description')}
        actions={
          next ? (
            <Button href={safeNext(next)} variant="secondary" iconLeft="arrow_back">
              {t('kyc.back')}
            </Button>
          ) : undefined
        }
      />

      {recipient}

      <div className="grid items-start gap-5 xl:grid-cols-2">
        <Card padding="none">
          <div className="px-4 pt-4 md:px-5 md:pt-5">
            <CardHeader className="mb-2">
              <CardTitle>{t('payout.listTitle')}</CardTitle>
              <CardDescription>{t('payout.listDescription')}</CardDescription>
            </CardHeader>
          </div>
          {list.length === 0 ? (
            <EmptyState compact icon="account_balance" title={t('payout.emptyTitle')} body={t('payout.emptyBody')} />
          ) : (
            <ul className="divide-y divide-border">
              {list.map((m) => (
                <li key={m.id} className="flex items-center gap-3 px-4 py-3.5 md:px-5">
                  <span className="grid size-10 shrink-0 place-items-center rounded-[30%] bg-subtle text-text-2">
                    <Icon name={m.kind === 'ewallet' ? 'account_balance_wallet' : 'account_balance'} size={22} />
                  </span>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-label text-ink">
                      {bankName(m.bank_code)} <span className="font-normal text-muted tnum">•••• {m.account_last4}</span>
                    </p>
                    <p className="truncate text-caption text-muted">{m.account_name}</p>
                  </div>
                  {m.verified_at ? (
                    <Badge tone="success" icon="verified" size="sm">
                      {t('payout.verified')}
                    </Badge>
                  ) : null}
                </li>
              ))}
            </ul>
          )}
        </Card>

        <Card padding="lg">
          <CardHeader>
            <CardTitle>{t('payout.addTitle')}</CardTitle>
            <CardDescription>{t('payout.addDescription')}</CardDescription>
          </CardHeader>
          {kycOk ? (
            <AddMethodForm kycName={kyc.data?.legal_name ?? ''} next={rewardType ? undefined : next} />
          ) : (
            <Alert
              tone="warn"
              title={t('payout.kycNeededTitle')}
              action={{ label: t('payout.kycNeededCta'), href: withParams('/kyc', { next: here }), linkAs: Link }}
            >
              {kyc.data?.status === 'rejected' ? t('payout.kycRejected') : t('payout.kycNeededBody')}
            </Alert>
          )}
        </Card>
      </div>

      {!rewardType && (
        <Card variant="tint" className="flex items-start gap-3">
          <Icon name="redeem" size={22} filled className="mt-0.5 shrink-0 text-primary-soft-fg" />
          <p className="text-body-s text-text-2">{t('recipient.hint')}</p>
        </Card>
      )}
    </div>
  );
}
