import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { hasRole, type Claims } from '@clipper/auth';
import { coreServer, getAuth } from '@clipper/auth/server';
import { identityApi } from '@clipper/db-identity';
import { Alert, Avatar, Badge, Card, CardHeader, CardTitle, formatDateTime, formatNumber, Icon, PlatformChip, RelativeTime, StatusBadge, type Platform, type UiLocale } from '@clipper/ui';
import { must, rows } from '@/lib/data';
import { ActionDialog } from '@/features/shared/action-dialog';
import { banUser, kycDecision, kycNotify, unbanUser } from './actions';
import { trustScore } from './trust';

export const KYC_REJECT_REASONS = ['photo_unreadable', 'name_mismatch', 'nik_invalid', 'not_ktp', 'duplicate', 'other'] as const;

/** F-A07 / A2.1 detail clipper: profil, Trust Score (riwayat E-40), akun sosmed, KYC identity (admin_read, tercatat E-24). */
export async function UserDetail({ userId, claims, loc }: { userId: string; claims: Claims; loc: UiLocale }) {
  const [t, db, { supabase }] = await Promise.all([getTranslations('admin'), coreServer('admin'), getAuth('admin')]);
  const isMod = hasRole(claims, 'admin_moderator');
  const canReadKyc = hasRole(claims, 'admin_moderator', 'admin_support', 'admin_finance');
  const [profRes, scoreRes, acctRes, flagRes, decRes] = await Promise.all([
    db.from('profiles').select('id, username, display_name, avatar_path, created_at').eq('id', userId).maybeSingle(),
    db.from('score_events').select('id, delta, reason, created_at').eq('user_id', userId).order('created_at', { ascending: false }).limit(5000),
    db.from('social_accounts').select('id, platform, handle, status, followers, verified_at').eq('user_id', userId),
    db.from('fraud_flags').select('id, signal, status, score, created_at').eq('target_type', 'profile').eq('target_id', userId).order('created_at', { ascending: false }).limit(10),
    db.from('review_decisions').select('decision, reason_code, created_at').eq('target_type', 'kyc').eq('target_id', userId).order('created_at', { ascending: false }).limit(1),
  ]);
  const p = must(profRes);
  if (!p) return <Alert tone="warn">{t('users.userMissing')}</Alert>;
  const scores = rows(scoreRes);
  const lastCore = rows(decRes)[0];

  let kyc: { legal_name: string; nik_last4: string; status: string; submitted_at: string; doc_ref: string; payout_methods: unknown } | null = null;
  let kycError: string | null = null;
  let photo: string | null = null;
  if (canReadKyc) {
    const { data, error } = await identityApi(supabase).schema('api').rpc('admin_read', { p_user_id: userId });
    if (error) kycError = t('users.kycReadFailed');
    else kyc = data?.[0] ?? null;
    if (kyc?.doc_ref && isMod) {
      photo = (await supabase.storage.from('kyc-docs').createSignedUrl(kyc.doc_ref, 60)).data?.signedUrl ?? null;
    }
  }
  const methods = (Array.isArray(kyc?.payout_methods) ? kyc.payout_methods : []) as { id: string; bank_code: string; last4: string; name: string }[];
  const decided = kyc && kyc.status !== 'pending' ? (kyc.status === 'approved' ? 'approve' : 'reject') : null;
  const needsNotify = decided && lastCore?.decision !== decided;

  return (
    <div className="mb-6 grid gap-5 lg:grid-cols-2">
      <Card padding="md" className="flex flex-col gap-4">
        <Link href="/users" className="inline-flex items-center gap-1 text-body-s font-semibold text-link focus-ring">
          <Icon name="arrow_back" size={16} />
          {t('users.back')}
        </Link>
        <div className="flex items-center gap-3">
          <Avatar name={p.display_name ?? p.username ?? '?'} size={48} />
          <div className="min-w-0">
            <p className="text-h5 break-words text-ink">{p.display_name}</p>
            <p className="text-body-s text-muted">@{p.username}</p>
          </div>
          <div className="ml-auto text-right">
            <p className="text-caption text-muted">{t('users.trustScore')}</p>
            <p className="text-h4 tnum text-ink">{trustScore(scores.map((s) => Number(s.delta ?? 0)))}</p>
          </div>
        </div>
        <p className="text-caption text-muted">
          {t('users.joined')} {formatDateTime(p.created_at!, loc)} · <code className="font-mono">{p.id}</code>
        </p>
        <Alert tone="info">{t('users.statusGap')}</Alert>
        {isMod ? (
          <div className="flex flex-wrap gap-2">
            <ActionDialog
              trigger={{ label: t('users.ban'), variant: 'danger', icon: 'block' }}
              title={t('users.banTitle')}
              description={t('users.banBody')}
              tone="danger"
              submitLabel={t('users.ban')}
              success={t('users.banned')}
              action={banUser.bind(null, userId)}
              fields={[
                { kind: 'select', name: 'duration', label: t('users.banDuration'), required: true, options: ['720h', '2160h', 'permanent', 'custom'].map((v) => ({ value: v, label: t(`users.durations.${v}`) })) },
                { kind: 'number', name: 'hours', label: t('users.banHours'), helper: t('users.banHoursHelp'), min: 1, max: 876000, step: '1' },
              ]}
            />
            <ActionDialog trigger={{ label: t('users.unban'), icon: 'undo' }} title={t('users.unban')} submitLabel={t('users.unban')} success={t('users.unbanned')} action={unbanUser.bind(null, userId)} />
          </div>
        ) : null}
        <section className="flex flex-col gap-2">
          <h3 className="text-label text-ink">{t('users.socialAccounts')}</h3>
          {rows(acctRes).length === 0 ? <p className="text-body-s text-muted">—</p> : null}
          <ul className="flex flex-col gap-1.5">
            {rows(acctRes).map((a) => (
              <li key={a.id} className="flex flex-wrap items-center gap-2 text-body-s">
                <PlatformChip platform={a.platform as Platform} />
                <span className="font-semibold text-ink">@{a.handle}</span>
                <span className="tnum text-muted">{t('users.followers', { n: formatNumber(Number(a.followers ?? 0), loc) })}</span>
                <Badge tone={a.status === 'verified' ? 'success' : 'warn'} size="sm">{a.status}</Badge>
              </li>
            ))}
          </ul>
        </section>
        <section className="flex flex-col gap-2">
          <h3 className="text-label text-ink">{t('users.scoreHistory')}</h3>
          <ul className="flex flex-col gap-1 text-body-s">
            {scores.slice(0, 10).map((s) => (
              <li key={s.id} className="flex justify-between gap-3">
                <span className="text-text-2">{t.has(`users.scoreReasons.${s.reason}`) ? t(`users.scoreReasons.${s.reason}`) : s.reason}</span>
                <span className={Number(s.delta) < 0 ? 'tnum font-semibold text-danger-fg' : 'tnum font-semibold text-success-fg'}>
                  {Number(s.delta) > 0 ? '+' : ''}
                  {s.delta} · <RelativeTime value={s.created_at!} locale={loc} />
                </span>
              </li>
            ))}
            {scores.length === 0 ? <li className="text-muted">—</li> : null}
          </ul>
        </section>
        {rows(flagRes).length ? (
          <section className="flex flex-col gap-2">
            <h3 className="text-label text-ink">{t('users.flags')}</h3>
            <div className="flex flex-wrap gap-1.5">
              {rows(flagRes).map((f) => (
                <Link key={f.id} href={`/fraud?signal=${f.signal}`}>
                  <Badge tone={f.status === 'open' || f.status === 'held' ? 'danger' : 'neutral'}>
                    {f.signal} · {f.status}
                  </Badge>
                </Link>
              ))}
            </div>
          </section>
        ) : null}
      </Card>

      <Card padding="md" className="flex flex-col gap-4">
        <CardHeader>
          <CardTitle>{t('users.kyc')}</CardTitle>
        </CardHeader>
        {!canReadKyc ? (
          <p className="text-body-s text-muted">{t('users.kycNoAccess')}</p>
        ) : kycError ? (
          <Alert tone="danger">{kycError}</Alert>
        ) : !kyc ? (
          <p className="text-body-s text-muted">{t('users.kycNone')}</p>
        ) : (
          <>
            <div className="flex flex-wrap items-center gap-2">
              <StatusBadge kind="kyc" status={kyc.status as 'pending'} label={t(`status.kyc.${kyc.status}`)} />
              <span className="text-caption text-muted">
                {t('users.submitted')} {formatDateTime(kyc.submitted_at, loc)}
              </span>
            </div>
            <dl className="grid grid-cols-2 gap-3 text-body-s">
              <div>
                <dt className="text-caption text-muted">{t('users.legalName')}</dt>
                <dd className="font-semibold break-words text-ink">{kyc.legal_name}</dd>
              </div>
              <div>
                <dt className="text-caption text-muted">{t('users.nik')}</dt>
                <dd className="font-mono font-semibold text-ink">•••• •••• •••• {kyc.nik_last4}</dd>
              </div>
            </dl>
            {isMod ? (
              photo ? (
                <a href={photo} target="_blank" rel="noopener noreferrer" className="block focus-ring">
                  <img src={photo} alt={t('users.ktpPhoto')} className="max-h-72 w-full rounded-card-sm bg-subtle object-contain" />
                  <span className="mt-1 inline-block text-caption text-link">{t('users.ktpOpen')}</span>
                </a>
              ) : (
                <p className="text-body-s text-muted">{t('users.ktpMissing')}</p>
              )
            ) : (
              <p className="text-caption text-muted">{t('users.ktpModeratorOnly')}</p>
            )}
            {methods.length ? (
              <section className="flex flex-col gap-1.5">
                <h3 className="text-label text-ink">{t('users.payoutMethods')}</h3>
                {methods.map((m) => (
                  <p key={m.id} className="text-body-s text-text-2">
                    {m.bank_code.toUpperCase()} ••{m.last4} · {m.name}
                  </p>
                ))}
              </section>
            ) : null}
            {isMod && kyc.status === 'pending' ? (
              <div className="flex flex-wrap gap-2 border-t border-border pt-3">
                <ActionDialog
                  trigger={{ label: t('users.kycReject'), variant: 'danger', icon: 'block', size: 'md' }}
                  title={t('users.kycReject')}
                  tone="danger"
                  submitLabel={t('users.kycReject')}
                  success={t('users.kycDecided')}
                  action={kycDecision.bind(null, userId, 'reject')}
                  fields={[
                    { kind: 'select', name: 'reason', label: t('users.reason'), required: true, options: KYC_REJECT_REASONS.map((r) => ({ value: r, label: t(`users.kycReasons.${r}`) })) },
                    { kind: 'textarea', name: 'message', label: t('users.messageToUser'), maxLength: 500 },
                  ]}
                />
                <ActionDialog
                  trigger={{ label: t('users.kycApprove'), variant: 'primary', icon: 'verified', size: 'md' }}
                  title={t('users.kycApprove')}
                  description={t('users.kycApproveBody')}
                  submitLabel={t('users.kycApprove')}
                  success={t('users.kycDecided')}
                  action={kycDecision.bind(null, userId, 'approve')}
                />
              </div>
            ) : null}
            {isMod && needsNotify ? (
              <Alert tone="warn" title={t('users.notifyPending')}>
                <ActionDialog
                  trigger={{ label: t('users.notifyNow'), icon: 'send' }}
                  title={t('users.notifyNow')}
                  submitLabel={t('users.notifyNow')}
                  success={t('users.notified')}
                  action={kycNotify.bind(null, userId, decided!, decided === 'reject' ? 'other' : null)}
                />
              </Alert>
            ) : null}
          </>
        )}
        <p className="text-caption text-muted">{t('users.kycAudit')}</p>
      </Card>
    </div>
  );
}
