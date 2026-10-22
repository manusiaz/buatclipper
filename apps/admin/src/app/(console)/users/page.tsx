import type { Metadata } from 'next';
import Link from 'next/link';
import { getLocale, getTranslations } from 'next-intl/server';
import { hasRole, type Claims } from '@clipper/auth';
import { brandServer, coreServer, getAuth, requireAdmin } from '@clipper/auth/server';
import { identityApi } from '@clipper/db-identity';
import {
  Alert,
  Avatar,
  Badge,
  Card,
  CardDescription,
  CardHeader,
  CardTitle,
  EmptyState,
  formatDateTime,
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
import { isUuid, likeTerm, param, rows, uniq, type SearchParams } from '@/lib/data';
import { adminInvite, adminResetMfa, adminSetRole } from '@/features/users/actions';
import { OrgDetail } from '@/features/users/org-detail';
import { UserDetail } from '@/features/users/user-detail';
import { ActionDialog, type FieldSpec } from '@/features/shared/action-dialog';
import { FilterBar } from '@/features/shared/filter-bar';
import { TabLinks } from '@/features/shared/tab-links';
import { rolesFor } from '@/features/shell/nav';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('admin'))('nav.users') };
}

const ROLES = ['admin_super', 'admin_ops', 'admin_moderator', 'admin_finance', 'admin_support'] as const;
const ORG_STATUSES = ['pending_verification', 'verified', 'suspended'] as const;
const KYC_STATUSES = ['pending', 'approved', 'rejected'] as const;

// F-A07 / J-A2: clipper (status, Trust Score, ban), antrean KYC, org brand (verifikasi, fee, anggota), admin (role E-27).
export default async function UsersPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { claims } = await requireAdmin(...rolesFor('users'));
  const [t, locale, sp, db] = await Promise.all([getTranslations('admin'), getLocale(), searchParams, coreServer('admin')]);
  const loc = locale as UiLocale;
  const isSuper = claims.app_roles.includes('admin_super');
  const isMod = hasRole(claims, 'admin_moderator');
  const raw = param(sp, 'tab');
  const tab = raw === 'org' || (raw === 'admin' && isSuper) || (raw === 'kyc' && isMod) ? raw : 'clipper';
  const q = param(sp, 'q');
  const pending = await (await brandServer('admin')).from('organizations').select('id', { count: 'exact', head: true }).eq('status', 'pending_verification');

  return (
    <>
      <PageHeader title={t('users.title')} description={t('users.description')} />
      <TabLinks
        label={t('users.title')}
        active={tab}
        tabs={[
          { key: 'clipper', href: '/users', label: t('users.tabClipper'), icon: 'person' },
          ...(isMod ? [{ key: 'kyc', href: '/users?tab=kyc', label: t('users.tabKyc'), icon: 'id_card' as const }] : []),
          { key: 'org', href: '/users?tab=org', label: t('users.tabOrg'), icon: 'storefront', count: pending.count ?? 0 },
          ...(isSuper ? [{ key: 'admin', href: '/users?tab=admin', label: t('users.tabAdmin'), icon: 'admin_panel_settings' as const }] : []),
        ]}
      />
      {!hasRole(claims, 'admin_ops', 'admin_moderator') ? (
        <Alert tone="info" className="mb-4">
          {t('users.readOnly')}
        </Alert>
      ) : null}
      {tab === 'clipper' ? <ClipperTab q={q} user={param(sp, 'user')} loc={loc} claims={claims} /> : null}
      {tab === 'kyc' ? <KycTab status={param(sp, 'status')} user={param(sp, 'user')} loc={loc} claims={claims} /> : null}
      {tab === 'org' ? <OrgTab q={q} status={param(sp, 'status')} org={param(sp, 'org')} loc={loc} claims={claims} /> : null}
      {tab === 'admin' ? <AdminTab loc={loc} /> : null}
    </>
  );
}

async function ClipperTab({ q, user, loc, claims }: { q: string; user: string; loc: UiLocale; claims: Claims }) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  let query = db
    .from('admin_profiles')
    .select('id, username, display_name, trust_score, status, created_at')
    .order('created_at', { ascending: false })
    .limit(30);
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
                  {p.status !== 'active' ? <StatusBadge kind="profile" status={p.status!} label={t(`status.profile.${p.status}`)} /> : null}
                  <span className="w-10 text-right text-sm font-semibold tnum text-ink" title={t('users.trustScore')}>
                    {p.trust_score}
                  </span>
                  <RelativeTime value={p.created_at!} locale={loc} className="hidden text-caption text-muted sm:inline" />
                </Link>
              </li>
            ))}
          </ul>
        </Card>
      )}
    </>
  );
}

/** Antrean KYC (identity api.admin_kyc_queue, tanpa PII); baris membuka detail user (admin_read + keputusan). */
async function KycTab({ status, user, loc, claims }: { status: string; user: string; loc: UiLocale; claims: Claims }) {
  const [t, db, { supabase }] = await Promise.all([getTranslations('admin'), coreServer('admin'), getAuth('admin')]);
  const st = KYC_STATUSES.includes(status as never) ? status : 'pending';
  const { data, error } = await identityApi(supabase).rpc('admin_kyc_queue', { p_status: st, p_limit: 200 });
  if (error) throw new Error(error.message);
  const queue = data ?? [];
  const ids = uniq(queue.map((k) => k.user_id));
  const profiles = new Map(
    ids.length ? rows(await db.from('admin_profiles').select('id, username, display_name, trust_score').in('id', ids)).map((p) => [p.id, p]) : [],
  );
  const back = `/users?tab=kyc&status=${st}`;
  return (
    <>
      {isUuid(user) ? <UserDetail userId={user} claims={claims} loc={loc} back={back} /> : null}
      <FilterBar
        submitLabel={t('form.apply')}
        resetHref="/users?tab=kyc"
        resetLabel={t('form.reset')}
        hidden={{ tab: 'kyc' }}
        filters={[
          { kind: 'select', name: 'status', label: t('users.kycStatus'), value: st, options: KYC_STATUSES.map((s) => ({ value: s, label: t(`status.kyc.${s}`) })) },
        ]}
      />
      {queue.length === 0 ? (
        <EmptyState icon="id_card" tone="success" title={t('users.kycQueueEmpty')} />
      ) : (
        <Table card caption={t('users.tabKyc')}>
          <THead>
            <TR>
              <TH>{t('users.user')}</TH>
              <TH>{t('users.kycStatus')}</TH>
              <TH align="right">{st === 'pending' ? t('users.submitted') : t('users.decidedAt')}</TH>
            </TR>
          </THead>
          <TBody>
            {queue.map((k) => {
              const p = profiles.get(k.user_id);
              return (
                <TR key={k.user_id} selected={k.user_id === user} interactive>
                  <TD>
                    <Link href={`${back}&user=${k.user_id}`} className="font-semibold break-words text-ink hover:text-link focus-ring">
                      {p ? `${p.display_name} · @${p.username}` : k.user_id}
                    </Link>
                    {k.reject_reason ? <span className="block text-caption text-muted">{t.has(`users.kycReasons.${k.reject_reason}`) ? t(`users.kycReasons.${k.reject_reason}`) : k.reject_reason}</span> : null}
                  </TD>
                  <TD>
                    <StatusBadge kind="kyc" status={k.status as 'pending'} label={t(`status.kyc.${k.status}`)} />
                  </TD>
                  <TD align="right" muted>
                    <RelativeTime value={(st === 'pending' ? k.submitted_at : k.decided_at) ?? k.submitted_at} locale={loc} />
                  </TD>
                </TR>
              );
            })}
          </TBody>
        </Table>
      )}
      <p className="mt-3 text-caption text-muted">{t('users.kycAudit')}</p>
    </>
  );
}

async function OrgTab({ q, status, org, loc, claims }: { q: string; status: string; org: string; loc: UiLocale; claims: Claims }) {
  const [t, db] = await Promise.all([getTranslations('admin'), brandServer('admin')]);
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

/** Daftar admin (identity api.admin_list_roles, admin_super) + undang / ubah role / reset MFA per baris. */
async function AdminTab({ loc }: { loc: UiLocale }) {
  const [t, { supabase }, { claims }] = await Promise.all([getTranslations('admin'), getAuth('admin'), requireAdmin('admin_super')]);
  const { data, error } = await identityApi(supabase).rpc('admin_list_roles');
  if (error) throw new Error(error.message);
  const admins = data ?? [];
  const roleOptions = ROLES.map((r) => ({ value: r, label: t(`roles.${r}`) }));
  const roleFields = (withUser: boolean): FieldSpec[] => [
    ...(withUser ? [{ kind: 'text', name: 'user_id', label: t('users.userId'), required: true } as FieldSpec] : []),
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
  ];

  return (
    <div className="flex flex-col gap-5">
      <Card padding="md" className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <CardHeader>
          <CardTitle>{t('users.inviteAdmin')}</CardTitle>
          <CardDescription>{t('users.inviteAdminBody')}</CardDescription>
        </CardHeader>
        <div className="flex flex-wrap gap-2">
          <ActionDialog
            trigger={{ label: t('users.inviteAdmin'), icon: 'person_add', variant: 'primary', size: 'md' }}
            title={t('users.inviteAdmin')}
            submitLabel={t('users.invite')}
            success={t('users.invited')}
            action={adminInvite}
            fields={[
              { kind: 'email', name: 'email', label: t('users.email'), required: true, maxLength: 254 },
              { kind: 'select', name: 'role', label: t('users.role'), required: true, options: roleOptions, defaultValue: 'admin_support' },
            ]}
          />
          <ActionDialog
            trigger={{ label: t('users.setRoleById'), icon: 'manage_accounts', size: 'md' }}
            title={t('users.setRole')}
            description={t('users.setRoleBody')}
            submitLabel={t('form.save')}
            success={t('users.roleSaved')}
            action={adminSetRole.bind(null, null)}
            fields={roleFields(true)}
          />
        </div>
      </Card>
      {admins.length === 0 ? (
        <EmptyState icon="admin_panel_settings" tone="neutral" title={t('users.noAdmins')} />
      ) : (
        <Table card caption={t('users.tabAdmin')}>
          <THead>
            <TR>
              <TH>{t('users.email')}</TH>
              <TH>{t('users.role')}</TH>
              <TH className="hidden md:table-cell">{t('users.since')}</TH>
              <TH align="right">{t('form.actions')}</TH>
            </TR>
          </THead>
          <TBody>
            {admins.map((a) => (
              <TR key={a.user_id}>
                <TD>
                  <span className="font-semibold break-all text-ink">{a.email}</span>
                  {a.user_id === claims.sub ? <Badge tone="outline" size="sm" className="ml-2">{t('users.you')}</Badge> : null}
                  <code className="block font-mono text-[11px] text-muted">{a.user_id}</code>
                </TD>
                <TD>
                  <div className="flex flex-wrap gap-1">
                    {a.roles.map((r) => (
                      <Badge key={r} tone={r === 'admin_super' ? 'premium' : 'primary'} size="sm">
                        {t.has(`roles.${r}`) ? t(`roles.${r}`) : r}
                      </Badge>
                    ))}
                  </div>
                </TD>
                <TD muted className="hidden md:table-cell">
                  {formatDateTime(a.granted_at, loc)}
                </TD>
                <TD align="right">
                  <div className="flex flex-wrap justify-end gap-2">
                    <ActionDialog
                      trigger={{ label: t('users.setRole'), icon: 'manage_accounts', variant: 'tertiary' }}
                      title={t('users.setRole')}
                      description={a.email}
                      submitLabel={t('form.save')}
                      success={t('users.roleSaved')}
                      action={adminSetRole.bind(null, a.user_id)}
                      fields={roleFields(false)}
                    />
                    {a.user_id !== claims.sub ? (
                      <ActionDialog
                        trigger={{ label: t('users.resetMfa'), icon: 'key', variant: 'ghost' }}
                        title={t('users.resetMfa')}
                        description={`${a.email} — ${t('users.resetMfaBody')}`}
                        tone="danger"
                        submitLabel={t('users.resetMfa')}
                        success={t('users.mfaReset')}
                        action={adminResetMfa.bind(null, a.user_id)}
                      />
                    ) : null}
                  </div>
                </TD>
              </TR>
            ))}
          </TBody>
        </Table>
      )}
    </div>
  );
}
