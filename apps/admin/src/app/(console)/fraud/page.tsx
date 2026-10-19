import type { Metadata } from 'next';
import Link from 'next/link';
import { getLocale, getTranslations } from 'next-intl/server';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import { Badge, Card, EmptyState, formatIDR, PageHeader, PlatformChip, RelativeTime, type Platform, type UiLocale } from '@clipper/ui';
import { param, rows, uniq, type SearchParams } from '@/lib/data';
import { resolveFlag, type FraudAction } from '@/features/fraud/actions';
import { ActionDialog } from '@/features/shared/action-dialog';
import { FilterBar } from '@/features/shared/filter-bar';
import { JsonView } from '@/features/shared/json-view';
import { rolesFor } from '@/features/shell/nav';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('admin'))('nav.fraud') };
}

const SIGNALS = Array.from({ length: 11 }, (_, i) => `FR-${String(i + 1).padStart(2, '0')}`);
const TARGETS = ['submission', 'profile', 'social_account', 'payout'] as const;

// F-A06 / A4.2: sinyal FR-xx (§12) per submisi/akun/payout dengan skor → hold / reverse / suspend / ban / dismiss.
export default async function FraudPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  await requireAdmin(...rolesFor('fraud'));
  const [t, locale, sp, db] = await Promise.all([getTranslations('admin'), getLocale(), searchParams, coreServer('admin')]);
  const loc = locale as UiLocale;
  const status = param(sp, 'status');
  const signal = param(sp, 'signal');
  const target = param(sp, 'target');

  let q = db.from('fraud_flags').select('id, target_type, target_id, signal, score, status, details, created_at')
    .in('status', status === 'open' || status === 'held' ? [status] : ['open', 'held'])
    .order('score', { ascending: false, nullsFirst: false }).order('created_at').limit(100);
  if (SIGNALS.includes(signal)) q = q.eq('signal', signal);
  if (TARGETS.includes(target as never)) q = q.eq('target_type', target);
  const flags = rows(await q);
  const idsOf = (type: string) => uniq(flags.filter((f) => f.target_type === type).map((f) => f.target_id));

  const [subs, accts, pays] = await Promise.all([
    db.from('submissions').select('id, user_id, campaign_id, url, platform, status').in('id', idsOf('submission')),
    db.from('social_accounts').select('id, user_id, platform, handle, followers').in('id', idsOf('social_account')),
    db.from('payouts').select('id, user_id, amount, status, channel').in('id', idsOf('payout')),
  ]);
  const sub = new Map(rows(subs).map((s) => [s.id, s]));
  const acct = new Map(rows(accts).map((a) => [a.id, a]));
  const pay = new Map(rows(pays).map((p) => [p.id, p]));
  const userIds = uniq([...idsOf('profile'), ...[...sub.values()].map((s) => s.user_id), ...[...acct.values()].map((a) => a.user_id), ...[...pay.values()].map((p) => p.user_id)]);
  const [profs, camps] = await Promise.all([
    db.from('profiles').select('id, username, display_name').in('id', userIds),
    db.from('campaigns').select('id, title').in('id', uniq([...sub.values()].map((s) => s.campaign_id))),
  ]);
  const prof = new Map(rows(profs).map((p) => [p.id, p]));
  const camp = new Map(rows(camps).map((c) => [c.id, c.title]));
  const all = { value: 'all', label: t('common.all') };

  const userOf = (f: (typeof flags)[number]) =>
    f.target_type === 'profile' ? f.target_id : f.target_type === 'submission' ? sub.get(f.target_id)?.user_id : f.target_type === 'social_account' ? acct.get(f.target_id)?.user_id : pay.get(f.target_id)?.user_id;

  const actionsFor = (f: (typeof flags)[number]): { a: FraudAction; variant: 'secondary' | 'danger' | 'tertiary'; noteRequired: boolean }[] => [
    ...(f.status === 'open' ? [{ a: 'hold' as const, variant: 'secondary' as const, noteRequired: false }] : []),
    ...(f.target_type === 'submission' || f.target_type === 'profile' ? [{ a: 'reverse' as const, variant: 'secondary' as const, noteRequired: true }] : []),
    { a: 'suspend', variant: 'secondary', noteRequired: true },
    { a: 'ban', variant: 'danger', noteRequired: true },
    { a: 'dismiss', variant: 'tertiary', noteRequired: false },
  ];

  return (
    <>
      <PageHeader title={t('fraud.title')} description={t('fraud.description')} />
      <FilterBar
        submitLabel={t('form.apply')}
        resetHref="/fraud"
        resetLabel={t('form.reset')}
        filters={[
          { kind: 'select', name: 'status', label: t('fraud.status'), value: status, options: [all, { value: 'open', label: t('fraud.statuses.open') }, { value: 'held', label: t('fraud.statuses.held') }] },
          { kind: 'select', name: 'signal', label: t('fraud.signal'), value: signal, options: [all, ...SIGNALS.map((s) => ({ value: s, label: `${s} · ${t(`fraud.signals.${s}`)}` }))] },
          { kind: 'select', name: 'target', label: t('fraud.target'), value: target, options: [all, ...TARGETS.map((x) => ({ value: x, label: t(`fraud.targets.${x}`) }))] },
        ]}
      />
      {flags.length === 0 ? (
        <EmptyState icon="shield" tone="success" title={t('fraud.empty')} body={t('fraud.emptyBody')} />
      ) : (
        <ul className="flex flex-col gap-3">
          {flags.map((f) => {
            const uid = userOf(f);
            const p = uid ? prof.get(uid) : undefined;
            const s = f.target_type === 'submission' ? sub.get(f.target_id) : undefined;
            const a = f.target_type === 'social_account' ? acct.get(f.target_id) : undefined;
            const py = f.target_type === 'payout' ? pay.get(f.target_id) : undefined;
            const score = Number(f.score ?? 0);
            return (
              <Card as="li" key={f.id} padding="md" className="flex flex-col gap-3">
                <div className="flex flex-wrap items-center gap-2">
                  <Badge tone={score >= 70 ? 'danger' : score >= 40 ? 'warn' : 'neutral'} className="tnum">
                    {f.signal} · {score}
                  </Badge>
                  <span className="font-semibold text-ink">{t.has(`fraud.signals.${f.signal}`) ? t(`fraud.signals.${f.signal}`) : f.signal}</span>
                  <Badge tone={f.status === 'held' ? 'warn' : 'primary'} dot>{t(`fraud.statuses.${f.status}`)}</Badge>
                  <RelativeTime value={f.created_at!} locale={loc} className="text-caption text-muted" />
                </div>
                <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-body-s">
                  <Badge tone="outline" size="sm">{t(`fraud.targets.${f.target_type}`)}</Badge>
                  {p ? (
                    <Link href={`/users?user=${p.id}`} className="font-semibold text-link hover:underline">
                      @{p.username}
                    </Link>
                  ) : null}
                  {s ? (
                    <>
                      <span className="text-text-2">{camp.get(s.campaign_id) ?? '—'}</span>
                      <PlatformChip platform={s.platform as Platform} />
                      <a href={s.url ?? '#'} target="_blank" rel="noopener noreferrer" className="max-w-xs truncate text-link hover:underline">
                        {s.url}
                      </a>
                    </>
                  ) : null}
                  {a ? (
                    <span className="text-text-2">
                      {a.platform} · @{a.handle}
                    </span>
                  ) : null}
                  {py ? <span className="tnum text-text-2">{formatIDR(Number(py.amount), { locale: loc })} · {py.channel}</span> : null}
                  {f.target_type === 'payout' && !py ? <span className="text-caption text-muted">{t('fraud.payoutHidden')}</span> : null}
                </div>
                <JsonView value={f.details} />
                <div className="flex flex-wrap gap-2 border-t border-border pt-3">
                  {actionsFor(f).map(({ a: act, variant, noteRequired }) => (
                    <ActionDialog
                      key={act}
                      trigger={{ label: t(`fraud.actions.${act}`), variant }}
                      title={t(`fraud.actions.${act}`)}
                      description={t(`fraud.actionHelp.${act}`)}
                      tone={act === 'ban' || act === 'suspend' ? 'danger' : 'primary'}
                      submitLabel={t(`fraud.actions.${act}`)}
                      success={t('fraud.resolved')}
                      action={resolveFlag.bind(null, f.id!, act)}
                      fields={[{ kind: 'textarea', name: 'note', label: t('form.internalNote'), required: noteRequired, maxLength: 1000 }]}
                    />
                  ))}
                </div>
              </Card>
            );
          })}
        </ul>
      )}
    </>
  );
}
