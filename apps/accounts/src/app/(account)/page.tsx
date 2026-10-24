import type { ReactNode } from 'react';
import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { hosts, onboardingUrl, safeNext } from '@clipper/auth';
import { mfaStatus, signOut } from '@clipper/auth/actions';
import { brandServer, coreServer, requireAccount } from '@clipper/auth/server';
import { Alert, Avatar, Badge, Button, Card, Icon, PageHeader, StatusBadge, type IconName } from '@clipper/ui';
import { consentSummary } from '@/features/privacy/consents';
import { identityDb } from '@/lib/identity';
import { one, withParams, type SearchParams } from '@/lib/url';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('accounts.meta'))('hub') };
}

export default async function HubPage({ searchParams }: { searchParams: SearchParams }) {
  const { claims } = await requireAccount();
  const next = one((await searchParams).next);
  const [t, id, core, brand, mfa] = await Promise.all([getTranslations('accounts'), identityDb(), coreServer(), brandServer(), mfaStatus('sso')]);
  const [kyc, methods, consents, profile, membership] = await Promise.all([
    id.from('my_kyc').select('status, reject_reason, legal_name, nik_last4').maybeSingle(),
    id.rpc('my_payout_methods'),
    id.from('my_consents').select('kind, version, granted_at, revoked_at'),
    core.from('my_profile').select('username, display_name, avatar_path').maybeSingle(),
    brand.from('org_members').select('org_id').eq('user_id', claims.sub).limit(1),
  ]);
  for (const r of [kyc, methods, consents]) if (r.error) throw new Error(r.error.message);

  const q = (href: string) => withParams(href, { next });
  const kycStatus = kyc.data?.status ?? 'none';
  const methodCount = methods.data?.length ?? 0;
  const consentCount = consentSummary(consents.data ?? []).filter((c) => c.active).length;
  const p = profile.data;
  const name = p?.display_name || claims.email || '';
  const avatar = p?.avatar_path ? `${process.env.NEXT_PUBLIC_CREATOR_DB_URL}/storage/v1/object/public/avatars/${p.avatar_path}` : null;

  const kycBody =
    kycStatus === 'approved'
      ? t('hub.kycApproved', { name: kyc.data?.legal_name ?? '', last4: kyc.data?.nik_last4 ?? '' })
      : kycStatus === 'rejected'
        ? t('hub.kycRejected', { reason: kyc.data?.reject_reason || t('kyc.noReason') })
        : t(`hub.kyc_${kycStatus}`);

  const cards: { href: string; icon: IconName; title: string; badge: ReactNode; body: string; cta: string }[] = [
    {
      href: '/kyc',
      icon: 'id_card',
      title: t('nav.kyc'),
      badge: <StatusBadge kind="kyc" status={kycStatus} label={t(`kyc.status.${kycStatus}`)} />,
      body: kycBody,
      cta: kycStatus === 'none' || kycStatus === 'rejected' ? t('hub.kycCta') : t('hub.view'),
    },
    {
      href: '/payout-methods',
      icon: 'account_balance',
      title: t('nav.payoutMethods'),
      badge: <Badge tone={methodCount ? 'success' : 'neutral'}>{t('hub.methodCount', { count: methodCount })}</Badge>,
      body: methodCount ? t('hub.methodsSome') : t('hub.methodsNone'),
      cta: methodCount ? t('hub.manage') : t('hub.methodsCta'),
    },
    {
      href: '/security',
      icon: 'shield',
      title: t('nav.security'),
      badge: (
        <Badge tone={mfa.enrolled ? 'success' : 'warn'} icon={mfa.enrolled ? 'verified' : 'key'}>
          {mfa.enrolled ? t('hub.mfaOn') : t('hub.mfaOff')}
        </Badge>
      ),
      body: mfa.enrolled ? t('hub.mfaOnBody') : t('hub.mfaOffBody'),
      cta: mfa.enrolled ? t('hub.view') : t('hub.mfaCta'),
    },
    {
      href: '/privacy',
      icon: 'lock',
      title: t('nav.privacy'),
      badge: <Badge tone="neutral">{t('hub.consentCount', { count: consentCount })}</Badge>,
      body: t('hub.privacyBody'),
      cta: t('hub.manage'),
    },
  ];

  return (
    <div className="flex flex-col gap-5">
      <PageHeader
        title={t('hub.title')}
        description={t('hub.description')}
        actions={
          <>
            {membership.data?.length ? (
              <Button href={`${hosts.brand}/`} variant="secondary" iconLeft="storefront">
                {t('nav.toBrand')}
              </Button>
            ) : null}
            <Button href={safeNext(next)} iconRight="arrow_forward">
              {t('nav.backToApp')}
            </Button>
          </>
        }
      />

      <Card className="flex items-center gap-4">
        <Avatar name={name} src={avatar} size={56} />
        <div className="min-w-0 flex-1">
          <p className="truncate text-h6 text-ink">{name}</p>
          {p?.display_name && (
            <p className="truncate text-body-s text-muted">
              @{p.username}
              {claims.email ? ` · ${claims.email}` : ''}
            </p>
          )}
        </div>
      </Card>

      {!p && (
        <Alert
          tone="warn"
          title={t('hub.noProfileTitle')}
          action={{ label: t('hub.noProfileCta'), href: onboardingUrl('clipper', `${hosts.accounts}${q('/')}`) }}
        >
          {t('hub.noProfileBody')}
        </Alert>
      )}

      <ul className="grid gap-4 md:grid-cols-2">
        {cards.map((c) => (
          <li key={c.href}>
            <Link href={q(c.href)} className="group block h-full rounded-card focus-ring">
              <Card interactive className="flex h-full flex-col gap-3">
                <div className="flex items-start justify-between gap-3">
                  <span className="grid size-10 shrink-0 place-items-center rounded-[30%] bg-primary-soft text-primary-soft-fg">
                    <Icon name={c.icon} size={22} filled />
                  </span>
                  {c.badge}
                </div>
                <div className="min-w-0">
                  <h2 className="text-h6 text-ink">{c.title}</h2>
                  <p className="mt-1 text-body-s break-words text-muted">{c.body}</p>
                </div>
                <span className="mt-auto inline-flex items-center gap-0.5 text-label text-link">
                  {c.cta}
                  <Icon name="chevron_right" size={18} className="transition-transform duration-120 group-hover:translate-x-0.5" />
                </span>
              </Card>
            </Link>
          </li>
        ))}
      </ul>

      <form action={signOut.bind(null, 'sso')} className="flex justify-center pt-2 md:justify-start">
        <Button type="submit" variant="ghost" iconLeft="logout">
          {t('hub.signOut')}
        </Button>
      </form>
    </div>
  );
}
