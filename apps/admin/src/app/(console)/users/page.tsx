import type { Metadata } from 'next';
import Link from 'next/link';
import { getLocale, getTranslations } from 'next-intl/server';
import { hasRole, type Claims } from '@clipper/auth';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import {
  Alert,
  Avatar,
  Card,
  CardDescription,
  CardHeader,
  CardTitle,
  EmptyState,
  PageHeader,
  RelativeTime,
  StatusBadge,
  Table,
  TBody,
  TD,
  TH,
  THead,
  TR,
  type UiLocale,
} from '@clipper/ui';
import { isUuid, likeTerm, param, rows, type SearchParams } from '@/lib/data';
import { adminInvite, adminResetMfa, adminSetRole } from '@/features/users/actions';
import { OrgDetail } from '@/features/users/org-detail';
import { UserDetail } from '@/features/users/user-detail';
import { ActionDialog } from '@/features/shared/action-dialog';
import { FilterBar } from '@/features/shared/filter-bar';
import { TabLinks } from '@/features/shared/tab-links';
import { rolesFor } from '@/features/shell/nav';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('admin'))('nav.users') };
}

const ROLES = ['admin_super', 'admin_ops', 'admin_moderator', 'admin_finance', 'admin_support'] as const;
const ORG_STATUSES = ['pending_verification', 'verified', 'suspended'] as const;

// F-A07 / J-A2: clipper (KYC, Trust Score, ban), org brand (verifikasi, fee, anggota), admin (role E-27, undang, reset MFA).
export default async function UsersPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { claims } = await requireAdmin(...rolesFor('users'));
  const [t, locale, sp, db] = await Promise.all([getTranslations('admin'), getLocale(), searchParams, coreServer('admin')]);
  const loc = locale as UiLocale;
  const isSuper = claims.app_roles.includes('admin_super');
  const raw = param(sp, 'tab');
  const tab = raw === 'org' || (raw === 'admin' && isSuper) ? raw : 'clipper';
  const q = param(sp, 'q');
  const pending = await db.from('organizations').select('id', { count: 'exact', head: true }).eq('status', 'pending_verification');

  return (
    <>
      <PageHeader title={t('users.title')} description={t('users.description')} />
      <TabLinks
        label={t('users.title')}
        active={tab}
        tabs={[
          { key: 'clipper', href: '/users', label: t('users.tabClipper'), icon: 'person' },
          { key: 'org', href: '/users?tab=org', label: t('users.tabOrg'), icon: 'storefront', count: pending.count ?? 0 },
          ...(isSuper
            ? [{ key: 'admin', href: '/users?tab=admin', label: t('users.tabAdmin'), icon: 'admin_panel_settings' as const }]
            : []),
        ]}
      />
      {!hasRole(claims, 'admin_ops', 'admin_moderator') ? (
        <Alert tone="info" className="mb-4">
          {t('users.readOnly')}
        </Alert>
      ) : null}
      {tab === 'clipper' ? <ClipperTab q={q} user={param(sp, 'user')} loc={loc} claims={claims} /> : null}
      {tab === 'org' ? <OrgTab q={q} status={param(sp, 'status')} org={param(sp, 'org')} loc={loc} claims={claims} /> : null}
      {tab === 'admin' ? <AdminTab /> : null}
    </>
  );
}

async function ClipperTab({ q, user, loc, claims }: { q: string; user: string; loc: UiLocale; claims: Claims }) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  let query = db.from('profiles').select('id, username, display_name, created_at').order('created_at', { ascending: false }).limit(30);
  if (isUuid(q)) query = query.eq('id', q);
  else if (q) query = query.or(`username.ilike.${likeTerm(q)},display_name.ilike.${likeTerm(q)}`);
  const list = rows(await query);
  return (
    <>
      {isUuid(user) ? <UserDetail userId={user} claims={claims} loc={loc} /> : null}
      <FilterBar
        submitLabel={t('form.search')}
        resetHref="/users"
        resetLabel={t('form.reset')}
        filters={[{ kind: 'text', name: 'q', label: t('users.searchClipper'), value: q, placeholder: t('users.searchClipperHint') }]}
      />
      <Alert tone="info" className="mb-4">
        {t('users.kycQueueGap')}
      </Alert>
      {list.length === 0 ? (
        <EmptyState icon="person" tone="neutral" title={t('users.noUsers')} />
      ) : (
        <Card padding="none">
          <ul className="divide-y divide-border">
            {list.map((p) => (
              <li key={p.id}>
                <Link
                  href={`/users?user=${p.id}${q ? `&q=${encodeURIComponent(q)}` : ''}`}
                  aria-current={p.id === user ? 'true' : undefined}
                  className="flex min-h-14 items-center gap-3 px-4 py-3 hover:bg-subtle focus-ring aria-[current=true]:bg-primary-tint"
                >
                  <Avatar name={p.display_name ?? p.username ?? '?'} size={32} />
                  <span className="min-w-0 flex-1">
                    <span className="block truncate font-semibold text-ink">{p.display_name}</span>
                    <span className="block truncate text-caption text-muted">@{p.username}</span>
                  </span>
                  <RelativeTime value={p.created_at!} locale={loc} className="text-caption text-muted" />
                </Link>
              </li>
            ))}
          </ul>
        </Card>
      )}
    </>
  );
}

async function OrgTab({ q, status, org, loc, claims }: { q: string; status: string; org: string; loc: UiLocale; claims: Claims }) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  const st = status === 'all' ? null : ORG_STATUSES.includes(status as never) ? status : 'pending_verification';
  let query = db.from('organizations').select('id, name, org_type, status, created_at').order('created_at').limit(50);
  if (st) query = query.eq('status', st as (typeof ORG_STATUSES)[number]);
  if (q) query = query.ilike('name', likeTerm(q));
  const list = rows(await query);
  return (
    <>
      {isUuid(org) ? <OrgDetail orgId={org} claims={claims} loc={loc} /> : null}
      <FilterBar
        submitLabel={t('form.apply')}
        resetHref="/users?tab=org"
        resetLabel={t('form.reset')}
        hidden={{ tab: 'org' }}
        filters={[
          {
            kind: 'select',
            name: 'status',
            label: t('users.orgStatus'),
            value: st ?? 'all',
            options: [{ value: 'all', label: t('common.all') }, ...ORG_STATUSES.map((s) => ({ value: s, label: t(`status.org.${s}`) }))],
          },
          { kind: 'text', name: 'q', label: t('users.searchOrg'), value: q },
        ]}
      />
      {list.length === 0 ? (
        <EmptyState icon="storefront" tone="success" title={t('users.noOrgs')} />
      ) : (
        <Table card caption={t('users.tabOrg')}>
          <THead>
            <TR>
              <TH>{t('users.orgName')}</TH>
              <TH>{t('users.orgTypeLabel')}</TH>
              <TH>{t('users.orgStatus')}</TH>
              <TH align="right">{t('users.created')}</TH>
            </TR>
          </THead>
          <TBody>
            {list.map((o) => (
              <TR key={o.id} selected={o.id === org} interactive>
                <TD>
                  <Link
                    href={`/users?tab=org&org=${o.id}${st ? `&status=${st}` : '&status=all'}`}
                    className="font-semibold break-words text-ink hover:text-link focus-ring"
                  >
                    {o.name}
                  </Link>
                </TD>
                <TD muted>{t(`users.orgType.${o.org_type}`)}</TD>
                <TD>
                  <StatusBadge kind="org" status={o.status!} label={t(`status.org.${o.status}`)} />
                </TD>
                <TD align="right" muted>
                  <RelativeTime value={o.created_at!} locale={loc} />
                </TD>
              </TR>
            ))}
          </TBody>
        </Table>
      )}
    </>
  );
}

async function AdminTab() {
  const t = await getTranslations('admin');
  const roleOptions = ROLES.map((r) => ({ value: r, label: t(`roles.${r}`) }));
  return (
    <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
      <Alert tone="info" className="md:col-span-3">
        {t('users.adminListGap')}
      </Alert>
      <Card padding="md" className="flex flex-col gap-3">
        <CardHeader>
          <CardTitle>{t('users.inviteAdmin')}</CardTitle>
          <CardDescription>{t('users.inviteAdminBody')}</CardDescription>
        </CardHeader>
        <ActionDialog
          trigger={{ label: t('users.inviteAdmin'), icon: 'person_add', variant: 'primary' }}
          title={t('users.inviteAdmin')}
          submitLabel={t('users.invite')}
          success={t('users.invited')}
          action={adminInvite}
          fields={[
            { kind: 'email', name: 'email', label: t('users.email'), required: true, maxLength: 254 },
            { kind: 'select', name: 'role', label: t('users.role'), required: true, options: roleOptions, defaultValue: 'admin_support' },
          ]}
        />
      </Card>
      <Card padding="md" className="flex flex-col gap-3">
        <CardHeader>
          <CardTitle>{t('users.setRole')}</CardTitle>
          <CardDescription>{t('users.setRoleBody')}</CardDescription>
        </CardHeader>
        <ActionDialog
          trigger={{ label: t('users.setRole'), icon: 'manage_accounts' }}
          title={t('users.setRole')}
          submitLabel={t('form.save')}
          success={t('users.roleSaved')}
          action={adminSetRole}
          fields={[
            { kind: 'text', name: 'user_id', label: t('users.userId'), required: true },
            { kind: 'select', name: 'role', label: t('users.role'), required: true, options: roleOptions },
            {
              kind: 'select',
              name: 'grant',
              label: t('users.grantRevoke'),
              required: true,
              options: [
                { value: 'grant', label: t('users.grant') },
                { value: 'revoke', label: t('users.revoke') },
              ],
            },
          ]}
        />
      </Card>
      <Card padding="md" className="flex flex-col gap-3">
        <CardHeader>
          <CardTitle>{t('users.resetMfa')}</CardTitle>
          <CardDescription>{t('users.resetMfaBody')}</CardDescription>
        </CardHeader>
        <ActionDialog
          trigger={{ label: t('users.resetMfa'), icon: 'key', variant: 'danger' }}
          title={t('users.resetMfa')}
          description={t('users.resetMfaBody')}
          tone="danger"
          submitLabel={t('users.resetMfa')}
          success={t('users.mfaReset')}
          action={adminResetMfa}
          fields={[{ kind: 'text', name: 'user_id', label: t('users.userId'), required: true }]}
        />
      </Card>
    </div>
  );
}
