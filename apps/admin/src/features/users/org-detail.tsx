import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { hasRole, type Claims } from '@clipper/auth';
import { coreServer, getAuth } from '@clipper/auth/server';
import { identityApi } from '@clipper/db-identity';
import { Alert, Badge, Card, formatDateTime, Icon, RelativeTime, StatusBadge, type UiLocale } from '@clipper/ui';
import { must, rows, uniq } from '@/lib/data';
import { ActionDialog } from '@/features/shared/action-dialog';
import { orgAddMember, orgDecision, orgInvitePic, orgSetFee } from './actions';

export const ORG_REJECT_REASONS = ['npwp_invalid', 'legal_name_mismatch', 'address_incomplete', 'owner_kyc', 'not_business', 'other'] as const;
const ORG_ROLES = ['brand_owner', 'brand_manager', 'brand_finance', 'brand_viewer'] as const;

/** A2.2 detail org: badan → nama legal, NPWP, alamat; perorangan → status KYC pemilik (identity admin_read). */
export async function OrgDetail({ orgId, claims, loc }: { orgId: string; claims: Claims; loc: UiLocale }) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  const canAct = hasRole(claims, 'admin_ops');
  const [orgRes, memRes, decRes] = await Promise.all([
    db.from('organizations').select('id, name, org_type, legal_name, npwp, address, is_agency, status, verified_at, created_at').eq('id', orgId).maybeSingle(),
    db.from('org_members').select('user_id, role, created_at').eq('org_id', orgId),
    db.from('review_decisions').select('id, decision, reason_code, message, created_at').eq('target_type', 'org').eq('target_id', orgId).order('created_at', { ascending: false }).limit(10),
  ]);
  const o = must(orgRes);
  if (!o) return <Alert tone="warn">{t('users.orgMissing')}</Alert>;
  const members = rows(memRes);
  const profiles = new Map(rows(await db.from('profiles').select('id, username, display_name').in('id', uniq(members.map((m) => m.user_id)))).map((p) => [p.id, p]));
  const owner = members.find((m) => m.role === 'brand_owner');

  let ownerKyc: string | null = null;
  if (o.org_type === 'perorangan' && owner?.user_id && hasRole(claims, 'admin_moderator', 'admin_support', 'admin_finance')) {
    const { data, error } = await identityApi((await getAuth('admin')).supabase).schema('api').rpc('admin_read', { p_user_id: owner.user_id });
    ownerKyc = error ? 'error' : (data?.[0]?.status ?? 'none');
  }
  const reasonOptions = ORG_REJECT_REASONS.map((r) => ({ value: r, label: t(`users.orgReasons.${r}`) }));
  const roleOptions = ORG_ROLES.map((r) => ({ value: r, label: t(`users.orgRoles.${r}`) }));
  const fields: [string, string | null | undefined][] = [
    [t('users.orgTypeLabel'), t(`users.orgType.${o.org_type}`)],
    [t('users.legalName'), o.legal_name],
    [t('users.npwp'), o.npwp],
    [t('users.address'), o.address],
    [t('users.agency'), o.is_agency ? t('common.yes') : t('common.no')],
    [t('users.created'), formatDateTime(o.created_at!, loc)],
    [t('users.verifiedAt'), o.verified_at ? formatDateTime(o.verified_at, loc) : '—'],
  ];

  return (
    <Card padding="md" className="mb-6 flex flex-col gap-5">
      <Link href="/users?tab=org" className="inline-flex items-center gap-1 text-body-s font-semibold text-link focus-ring">
        <Icon name="arrow_back" size={16} />
        {t('users.back')}
      </Link>
      <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <h2 className="text-h4 break-words text-ink">{o.name}</h2>
          <StatusBadge kind="org" status={o.status!} label={t(`status.org.${o.status}`)} />
        </div>
        {canAct ? (
          <div className="flex flex-wrap gap-2">
            {o.status !== 'verified' ? (
              <ActionDialog
                trigger={{ label: t('users.orgVerify'), variant: 'primary', icon: 'verified', size: 'md' }}
                title={t('users.orgVerify')}
                description={o.name ?? ''}
                submitLabel={t('users.orgVerify')}
                success={t('users.orgDone')}
                action={orgDecision.bind(null, orgId, 'verify')}
                fields={[
                  { kind: 'textarea', name: 'message', label: t('users.messageToBrand'), maxLength: 500 },
                  { kind: 'textarea', name: 'note', label: t('form.internalNote'), maxLength: 500 },
                ]}
              />
            ) : null}
            {o.status === 'pending_verification' ? (
              <ActionDialog
                trigger={{ label: t('users.orgReject'), variant: 'danger', icon: 'block', size: 'md' }}
                title={t('users.orgReject')}
                description={t('users.orgRejectBody')}
                tone="danger"
                submitLabel={t('users.orgReject')}
                success={t('users.orgDone')}
                action={orgDecision.bind(null, orgId, 'reject')}
                fields={[
                  { kind: 'select', name: 'reason', label: t('users.reason'), required: true, options: reasonOptions },
                  { kind: 'textarea', name: 'message', label: t('users.messageToBrand'), required: true, maxLength: 500 },
                  { kind: 'textarea', name: 'note', label: t('form.internalNote'), maxLength: 500 },
                ]}
              />
            ) : null}
            {o.status === 'verified' ? (
              <ActionDialog
                trigger={{ label: t('users.orgSuspend'), variant: 'danger', icon: 'pause', size: 'md' }}
                title={t('users.orgSuspend')}
                description={t('users.orgSuspendBody')}
                tone="danger"
                submitLabel={t('users.orgSuspend')}
                success={t('users.orgDone')}
                action={orgDecision.bind(null, orgId, 'suspend')}
                fields={[
                  { kind: 'textarea', name: 'reason', label: t('users.reason'), required: true, maxLength: 500 },
                  { kind: 'textarea', name: 'message', label: t('users.messageToBrand'), maxLength: 500 },
                ]}
              />
            ) : null}
          </div>
        ) : null}
      </div>

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-2">
        <dl className="grid grid-cols-2 gap-3 text-body-s">
          {fields.map(([k, v]) => (
            <div key={k} className="min-w-0">
              <dt className="text-caption text-muted">{k}</dt>
              <dd className="font-semibold break-words text-ink">{v || '—'}</dd>
            </div>
          ))}
          {o.org_type === 'perorangan' ? (
            <div className="col-span-2">
              <dt className="text-caption text-muted">{t('users.ownerKyc')}</dt>
              <dd className="mt-1">
                {ownerKyc == null ? (
                  <span className="text-body-s text-muted">{t('users.ownerKycNoAccess')}</span>
                ) : ownerKyc === 'error' ? (
                  <span className="text-body-s text-danger-fg">{t('users.kycReadFailed')}</span>
                ) : (
                  <StatusBadge kind="kyc" status={ownerKyc as 'none'} label={t(`status.kyc.${ownerKyc}`)} />
                )}
              </dd>
            </div>
          ) : null}
        </dl>

        <section className="flex flex-col gap-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h3 className="text-label text-ink">{t('users.members')}</h3>
            {canAct ? (
              <div className="flex flex-wrap gap-2">
                <ActionDialog
                  trigger={{ label: t('users.invitePic'), icon: 'person_add' }}
                  title={t('users.invitePic')}
                  description={t('users.invitePicBody')}
                  submitLabel={t('users.invite')}
                  success={t('users.invited')}
                  action={orgInvitePic.bind(null, orgId, o.name ?? '')}
                  fields={[
                    { kind: 'email', name: 'email', label: t('users.email'), required: true, maxLength: 254 },
                    { kind: 'select', name: 'role', label: t('users.role'), required: true, options: roleOptions },
                  ]}
                />
                <ActionDialog
                  trigger={{ label: t('users.addMember'), icon: 'group_add', variant: 'tertiary' }}
                  title={t('users.addMember')}
                  description={t('users.addMemberBody')}
                  submitLabel={t('users.addMember')}
                  success={t('users.memberAdded')}
                  action={orgAddMember.bind(null, orgId)}
                  fields={[
                    { kind: 'text', name: 'user_id', label: t('users.userId'), required: true, placeholder: '00000000-0000-…' },
                    { kind: 'select', name: 'role', label: t('users.role'), required: true, options: roleOptions },
                  ]}
                />
              </div>
            ) : null}
          </div>
          <ul className="flex flex-col gap-1.5 text-body-s">
            {members.map((m) => {
              const p = profiles.get(m.user_id);
              return (
                <li key={m.user_id} className="flex flex-wrap items-center gap-2">
                  <span className="font-semibold text-ink">{p?.display_name ?? '—'}</span>
                  <span className="text-muted">@{p?.username ?? m.user_id}</span>
                  <Badge tone={m.role === 'brand_owner' ? 'primary' : 'neutral'} size="sm">{t(`users.orgRoles.${m.role}`)}</Badge>
                </li>
              );
            })}
            {members.length === 0 ? <li className="text-muted">—</li> : null}
          </ul>
          {canAct ? (
            <ActionDialog
              trigger={{ label: t('users.setFee'), icon: 'percent', variant: 'tertiary' }}
              title={t('users.setFee')}
              description={t('users.setFeeBody')}
              submitLabel={t('form.save')}
              success={t('users.feeSaved')}
              action={orgSetFee.bind(null, orgId)}
              fields={[
                { kind: 'number', name: 'mgmt_fee_pct', label: t('config.fee.mgmt_fee_pct'), min: 0, max: 100, step: '0.01', suffix: '%' },
                { kind: 'number', name: 'admin_fee_pct', label: t('config.fee.admin_fee_pct'), min: 0, max: 100, step: '0.01', suffix: '%' },
                { kind: 'number', name: 'clipper_fee_pct', label: t('config.fee.clipper_fee_pct'), min: 0, max: 100, step: '0.01', suffix: '%' },
                { kind: 'number', name: 'instant_withdraw_fee', label: t('config.fee.instant_withdraw_fee'), min: 0, step: '1', prefix: 'Rp' },
                { kind: 'checkbox', name: 'clear', label: t('users.feeClear') },
              ]}
            />
          ) : null}
        </section>
      </div>

      {rows(decRes).length ? (
        <section className="flex flex-col gap-2 border-t border-border pt-4">
          <h3 className="text-label text-ink">{t('users.history')}</h3>
          <ol className="flex flex-col gap-1 text-body-s">
            {rows(decRes).map((d) => (
              <li key={d.id} className="flex flex-wrap items-center gap-2">
                <Badge tone={d.decision === 'approve' ? 'success' : 'danger'} size="sm">{t(`review.decisions.${d.decision}`)}</Badge>
                {d.reason_code ? <span className="text-text-2">{t.has(`users.orgReasons.${d.reason_code}`) ? t(`users.orgReasons.${d.reason_code}`) : d.reason_code}</span> : null}
                {d.message ? <span className="text-muted">“{d.message}”</span> : null}
                <RelativeTime value={d.created_at!} locale={loc} className="text-caption text-faint" />
              </li>
            ))}
          </ol>
        </section>
      ) : null}
    </Card>
  );
}
