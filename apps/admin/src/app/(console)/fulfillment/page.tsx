import type { Metadata } from 'next';
import Link from 'next/link';
import { getLocale, getTranslations } from 'next-intl/server';
import { hasRole } from '@clipper/auth';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import {
  Badge,
  Card,
  CardDescription,
  CardHeader,
  CardTitle,
  cn,
  EmptyState,
  formatNumber,
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
import { isUuid, param, rows, uniq, type SearchParams } from '@/lib/data';
import { cancelFulfillment, exportRecipients, markDelivered, resignRecipients, retryFulfillment, uploadCodes } from '@/features/fulfillment/actions';
import { ActionButton, ActionDialog } from '@/features/shared/action-dialog';
import { ExportPanel } from '@/features/shared/export-panel';
import { JsonView } from '@/features/shared/json-view';
import { rolesFor } from '@/features/shell/nav';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('admin'))('nav.fulfillment') };
}

const ACTIVE = ['requested', 'on_hold', 'processing', 'failed'] as const;

// F-A10 / A5.1: antrean klaim reward non-tunai per reward type; export penerima (pii-export, consent share_with_brand); batal.
export default async function FulfillmentPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { claims } = await requireAdmin(...rolesFor('fulfillment'));
  const [t, locale, sp, db] = await Promise.all([getTranslations('admin'), getLocale(), searchParams, coreServer('admin')]);
  const loc = locale as UiLocale;
  const [rtRes, qRes] = await Promise.all([
    db
      .from('reward_types')
      .select('id, code, name, unit_label, fulfillment, owner_org_id, stock')
      .neq('fulfillment', 'payout')
      .order('name'),
    db
      .from('fulfillments')
      .select('reward_type_id, status')
      .in('status', [...ACTIVE])
      .limit(10000),
  ]);
  const types = rows(rtRes);
  const counts = new Map<string, number>();
  for (const f of rows(qRes)) counts.set(f.reward_type_id!, (counts.get(f.reward_type_id!) ?? 0) + 1);
  const pick = param(sp, 'type');
  const selected = types.find((r) => r.id === pick) ?? types.find((r) => counts.get(r.id!)) ?? types[0];
  const orgs = new Map(
    rows(
      await db
        .from('organizations')
        .select('id, name')
        .in('id', uniq(types.map((r) => r.owner_org_id))),
    ).map((o) => [o.id, o.name]),
  );

  return (
    <>
      <PageHeader title={t('fulfillment.title')} description={t('fulfillment.description')} />
      {types.length === 0 ? (
        <EmptyState icon="redeem" tone="neutral" title={t('fulfillment.noTypes')} />
      ) : (
        <div className="grid grid-cols-1 gap-5 lg:grid-cols-[280px_minmax(0,1fr)]">
          <Card padding="none" as="nav" aria-label={t('fulfillment.types')}>
            <ul className="flex flex-col p-2">
              {types.map((r) => (
                <li key={r.id}>
                  <Link
                    href={`/fulfillment?type=${r.id}`}
                    aria-current={r.id === selected?.id ? 'page' : undefined}
                    className={cn(
                      'flex min-h-12 items-center gap-2 rounded-[10px] px-3 py-2 text-sm hover:bg-subtle focus-ring',
                      'aria-[current=page]:bg-primary-tint aria-[current=page]:font-bold',
                    )}
                  >
                    <span className="min-w-0 flex-1">
                      <span className="block truncate font-semibold text-ink">{r.name}</span>
                      <span className="block truncate text-caption text-muted">
                        {t(`fulfillment.kinds.${r.fulfillment}`)} ·{' '}
                        {r.owner_org_id ? (orgs.get(r.owner_org_id) ?? '—') : t('fulfillment.global')}
                      </span>
                    </span>
                    {counts.get(r.id!) ? <Badge tone="primary">{counts.get(r.id!)}</Badge> : null}
                  </Link>
                </li>
              ))}
            </ul>
          </Card>
          {selected && isUuid(selected.id) ? <TypeQueue rt={selected} loc={loc} canOps={hasRole(claims, 'admin_ops')} /> : null}
        </div>
      )}
    </>
  );
}

async function TypeQueue({
  rt,
  loc,
  canOps,
}: {
  rt: { id: string | null; name: string | null; fulfillment: string | null; unit_label: string | null; stock: number | null };
  loc: UiLocale;
  canOps: boolean;
}) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  const id = rt.id!;
  const [listRes, freeRes, exportsRes] = await Promise.all([
    db
      .from('fulfillments')
      .select('id, user_id, amount, recipient, status, attempts, created_at, next_retry_at')
      .eq('reward_type_id', id)
      .in('status', [...ACTIVE])
      .order('created_at')
      .limit(200),
    rt.fulfillment === 'code_pool'
      ? db.from('reward_codes').select('id', { count: 'exact', head: true }).eq('reward_type_id', id).is('fulfillment_id', null)
      : Promise.resolve({ count: null }),
    rt.fulfillment === 'manual_export'
      ? db.from('fulfillment_exports').select('file_ref, pending').eq('reward_type_id', id).gt('pending', 0)
          .order('file_ref', { ascending: false }).limit(10)
      : Promise.resolve({ data: [], error: null }),
  ]);
  const list = rows(listRes);
  const exports = rows(exportsRes);
  const users = new Map(
    rows(
      await db
        .from('profiles')
        .select('id, username')
        .in('id', uniq(list.map((f) => f.user_id))),
    ).map((p) => [p.id, p.username]),
  );

  return (
    <div className="flex min-w-0 flex-col gap-4">
      <Card padding="md" className="flex flex-col gap-3">
        <CardHeader>
          <CardTitle>{rt.name}</CardTitle>
          <CardDescription>{t(`fulfillment.kindHelp.${rt.fulfillment}`)}</CardDescription>
        </CardHeader>
        {rt.fulfillment === 'manual_export' ? (
          <ExportPanel
            label={t('fulfillment.exportRecipients')}
            itemsTitle={t('fulfillment.skipped')}
            action={exportRecipients.bind(null, id)}
          />
        ) : null}
        {exports.map((e) => (
          <ExportPanel
            key={e.file_ref}
            label={t('fulfillment.redownload', { file: e.file_ref!.split('/').pop()!, n: formatNumber(e.pending ?? 0, loc) })}
            itemsTitle={t('fulfillment.skipped')}
            action={resignRecipients.bind(null, id, e.file_ref!, e.pending ?? 0)}
          />
        ))}
        {rt.fulfillment === 'code_pool' ? (
          <>
            <div className="flex flex-wrap items-center gap-3">
              <p className="text-body-s text-text-2">{t('fulfillment.freeCodes', { n: formatNumber(freeRes.count ?? 0, loc) })}</p>
              {canOps ? (
                <ActionDialog
                  trigger={{ label: t('fulfillment.uploadCodes'), icon: 'upload', variant: 'primary' }}
                  title={t('fulfillment.uploadCodes')}
                  description={t('fulfillment.uploadCodesBody')}
                  size="md"
                  submitLabel={t('fulfillment.upload')}
                  success={t('fulfillment.uploadCodes')}
                  successKey="fulfillment.codesUploaded"
                  action={uploadCodes.bind(null, id)}
                  fields={[
                    { kind: 'textarea', name: 'codes', label: t('fulfillment.codesText'), helper: t('fulfillment.codesTextHelp') },
                    {
                      kind: 'file',
                      name: 'file',
                      label: t('fulfillment.codesFile'),
                      accept: '.txt,.csv,text/plain,text/csv',
                      maxBytes: 2 * 1024 * 1024,
                    },
                  ]}
                />
              ) : null}
            </div>
          </>
        ) : null}
      </Card>
      {list.length === 0 ? (
        <EmptyState icon="check_circle" tone="success" title={t('fulfillment.empty')} />
      ) : (
        <Table card caption={rt.name ?? ''}>
          <THead>
            <TR>
              <TH>{t('fulfillment.user')}</TH>
              <TH align="right">{t('fulfillment.amount')}</TH>
              <TH>{t('fulfillment.recipient')}</TH>
              <TH>{t('fulfillment.status')}</TH>
              <TH align="right">{t('form.actions')}</TH>
            </TR>
          </THead>
          <TBody>
            {list.map((f) => (
              <TR key={f.id}>
                <TD>
                  <span className="font-semibold text-ink">@{users.get(f.user_id) ?? '—'}</span>
                  <span className="block text-caption text-muted">
                    <RelativeTime value={f.created_at!} locale={loc} />
                  </span>
                </TD>
                <TD numeric>
                  {formatNumber(Number(f.amount ?? 0), loc, { maximumFractionDigits: 2 })} {rt.unit_label}
                </TD>
                <TD>
                  <JsonView value={f.recipient} max={4} />
                </TD>
                <TD>
                  <StatusBadge kind="fulfillment" status={f.status!} label={t(`status.fulfillment.${f.status}`)} />
                  {Number(f.attempts) > 0 ? <span className="ml-2 text-caption text-muted">×{f.attempts}</span> : null}
                </TD>
                <TD align="right">
                  <div className="flex flex-wrap justify-end gap-2">
                    {canOps && rt.fulfillment === 'webhook' && f.status === 'on_hold' && f.next_retry_at ? (
                      <span className="text-caption text-muted">{t('fulfillment.retryScheduled')}</span>
                    ) : null}
                    {canOps && rt.fulfillment === 'webhook' && f.status === 'on_hold' && !f.next_retry_at ? (
                      <ActionButton label={t('fulfillment.retry')} icon="refresh" variant="secondary" success={t('fulfillment.retried')} action={retryFulfillment.bind(null, f.id!)} />
                    ) : null}
                    {canOps && (rt.fulfillment === 'manual_export' ? f.status !== 'failed' : rt.fulfillment === 'webhook' && f.status === 'on_hold' && !f.next_retry_at) ? (
                      <ActionDialog
                        trigger={{ label: t('fulfillment.markDelivered'), variant: 'secondary', icon: 'check' }}
                        title={t('fulfillment.markDelivered')}
                        description={t('fulfillment.markDeliveredBody')}
                        submitLabel={t('fulfillment.markDelivered')}
                        success={t('fulfillment.delivered')}
                        action={markDelivered.bind(null, f.id!)}
                        fields={[
                          {
                            kind: 'text',
                            name: 'ref',
                            label: t('fulfillment.ref'),
                            helper: t('fulfillment.refHelp'),
                            required: true,
                            maxLength: 200,
                          },
                        ]}
                      />
                    ) : null}
                    <ActionDialog
                      trigger={{ label: t('fulfillment.cancel'), variant: 'ghost', icon: 'cancel' }}
                      title={t('fulfillment.cancel')}
                      description={t('fulfillment.cancelBody')}
                      tone="danger"
                      submitLabel={t('fulfillment.cancel')}
                      success={t('fulfillment.cancelled')}
                      action={cancelFulfillment.bind(null, f.id!)}
                      fields={[
                        { kind: 'textarea', name: 'reason', label: t('form.reason'), required: true, maxLength: 500 },
                        { kind: 'checkbox', name: 'not_delivered', label: t('fulfillment.notDelivered'), helper: t('fulfillment.notDeliveredHelp') },
                      ]}
                    />
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
