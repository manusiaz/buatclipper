import type { ReactNode } from 'react';
import { getTranslations } from 'next-intl/server';
import { hosts, kycUrl } from '@clipper/auth';
import { Alert, ThemeToggle } from '@clipper/ui';
import { NotificationBell } from '@/features/notifications/bell';
import { BrandShell, type ShellNavItem } from '@/features/shell/brand-shell';
import { OrgSwitcher } from '@/features/shell/org-switcher';
import { UserMenu } from '@/features/shell/user-menu';
import { myName } from '@/features/shell/me';
import { pendingReviewCount } from '@/features/review/queries';
import { can, getOrgContext } from '@/lib/org';

export default async function OrgLayout({ children, params }: { children: ReactNode; params: Promise<{ org: string }> }) {
  const { org: orgId } = await params;
  const { claims, core, org, role } = await getOrgContext(orgId);
  const [t, name, { data: orgs }, { data: mine }, reviewCount] = await Promise.all([
    getTranslations('brand'),
    myName(claims.email),
    core.from('organizations').select('id, name, status').order('name'),
    core.from('org_members').select('org_id').eq('user_id', claims.sub),
    can(role, 'review') ? pendingReviewCount(core, orgId) : Promise.resolve(0),
  ]);
  const direct = new Set((mine ?? []).map((m) => m.org_id));
  const base = `/${orgId}`;
  const nav: ShellNavItem[] = [
    { href: `${base}/campaigns`, label: t('nav.campaigns'), icon: 'campaign' },
    ...(can(role, 'review') ? [{ href: `${base}/review`, label: t('nav.review'), icon: 'checklist' as const, badge: reviewCount }] : []),
    ...(can(role, 'billing') ? [{ href: `${base}/billing`, label: t('nav.billing'), icon: 'receipt_long' as const }] : []),
    { href: `${base}/reward-types`, label: t('nav.rewardTypes'), icon: 'redeem' },
    { href: `${base}/team`, label: t('nav.team'), icon: 'groups' },
    { href: `${base}/settings`, label: t('nav.settings'), icon: 'settings' },
  ];
  const needsKyc = org.org_type === 'perorangan' && role === 'brand_owner' && claims.kyc !== 'approved';
  const banner =
    org.status === 'suspended' ? (
      <Alert tone="danger" title={t('banner.suspendedTitle')}>{t('banner.suspendedBody')}</Alert>
    ) : org.status === 'pending_verification' ? (
      <Alert
        tone="warn"
        title={t('banner.pendingTitle')}
        action={needsKyc ? { label: t('banner.kycAction'), href: kycUrl(`${hosts.brand}${base}/campaigns`) } : undefined}
      >
        {needsKyc ? t('banner.pendingKyc') : t('banner.pendingBody')}
      </Alert>
    ) : null;

  return (
    <BrandShell
      nav={nav}
      orgSwitcher={
        <OrgSwitcher
          current={{ id: orgId, name: org.name, status: org.status ?? 'pending_verification' }}
          orgs={(orgs ?? []).flatMap((o) => (o.id && o.name ? [{ id: o.id, name: o.name, status: o.status ?? '', agency: !direct.has(o.id) }] : []))}
        />
      }
      headerActions={
        <>
          <ThemeToggle labels={{ toggle: t('shell.theme') }} />
          <NotificationBell core={core} userId={claims.sub} />
        </>
      }
      userMenu={<UserMenu name={name} email={claims.email} />}
      banner={banner}
      footer={<p className="px-3 text-caption text-muted">{t(`roles.${role}`)}</p>}
    >
      {children}
    </BrandShell>
  );
}
