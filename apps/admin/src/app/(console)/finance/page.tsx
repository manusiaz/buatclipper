import type { Metadata } from 'next';
import Link from 'next/link';
import { getLocale, getTranslations } from 'next-intl/server';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import {
  Alert, Badge, Button, Card, CardDescription, CardHeader, CardTitle, EmptyState, Field, formatDateTime, formatIDR, Input, PageHeader, RelativeTime,
  StatCard, StatusBadge, Table, TBody, TD, TH, THead, TR, type UiLocale,
} from '@clipper/ui';
import type { Claims } from '@clipper/auth';
import { isUuid, param, rows, uniq, type SearchParams } from '@/lib/data';
import { isoToWibDate, isoToWibInput } from '@/lib/wib';
import {
  approveBatch, approveRefund, cancelPayout, confirmInvoice, createBatch, exportPayoutCsv, exportPph21, uploadProof,
} from '@/features/finance/actions';
import { BatchResults } from '@/features/finance/batch-results';
import { ActionButton, ActionDialog, type FieldSpec } from '@/features/shared/action-dialog';
import { ExportPanel } from '@/features/shared/export-panel';
import { TabLinks } from '@/features/shared/tab-links';
import { rolesFor } from '@/features/shell/nav';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('admin'))('nav.finance') };
}

const TABS = ['incoming', 'payout', 'instant', 'refund', 'pph21'] as const;
type Tab = (typeof TABS)[number];
const idr = (v: unknown, loc: UiLocale) => formatIDR(Number(v ?? 0), { locale: loc });
const PROOF: FieldSpec = { kind: 'file', name: 'file', label: '', accept: 'application/pdf,image/jpeg,image/png', required: true, maxBytes: 10 * 1024 * 1024 };

// F-A08 / J-A3: pembayaran masuk, batch payout (dua orang) + CSV pii-export + tandai paid + bukti, instant, refund, PPh 21.
export default async function FinancePage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { claims } = await requireAdmin(...rolesFor('finance'));
  const [t, locale, sp] = await Promise.all([getTranslations('admin'), getLocale(), searchParams]);
  const loc = locale as UiLocale;
  const raw = param(sp, 'tab') as Tab;
  const tab: Tab = TABS.includes(raw) ? raw : 'incoming';

  return (
    <>
      <PageHeader title={t('finance.title')} description={t('finance.description')} />
      <TabLinks
        label={t('finance.title')}
        active={tab}
        tabs={TABS.map((k) => ({ key: k, href: k === 'incoming' ? '/finance' : `/finance?tab=${k}`, label: t(`finance.tabs.${k}`) }))}
      />
      {tab === 'incoming' ? <Incoming loc={loc} /> : null}
      {tab === 'payout' ? <Payouts loc={loc} claims={claims} batch={param(sp, 'batch')} /> : null}
      {tab === 'instant' ? <Instant loc={loc} /> : null}
      {tab === 'refund' ? <Refunds loc={loc} me={claims.sub} /> : null}
      {tab === 'pph21' ? <Pph21 /> : null}
    </>
  );
}

async function names(db: Awaited<ReturnType<typeof coreServer>>, userIds: (string | null)[]) {
  const ids = uniq(userIds);
  if (!ids.length) return new Map<string, string>();
  return new Map(rows(await db.from('profiles').select('id, username').in('id', ids)).map((p) => [p.id!, p.username ?? '—']));
}

async function Incoming({ loc }: { loc: UiLocale }) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  const [openRes, paidRes] = await Promise.all([
    db.from('invoices').select('id, number, org_id, campaign_id, kind, total, credit_applied, amount_due, issued_at, due_at').eq('status', 'issued').order('issued_at').limit(100),
    db.from('invoices').select('id, number, org_id, kind, paid_amount, paid_at, payment_channel').eq('status', 'paid').order('paid_at', { ascending: false }).limit(10),
  ]);
  const open = rows(openRes);
  const paid = rows(paidRes);
  const [orgs, camps] = await Promise.all([
    db.from('organizations').select('id, name').in('id', uniq([...open, ...paid].map((i) => i.org_id))),
    db.from('campaigns').select('id, title').in('id', uniq(open.map((i) => i.campaign_id))),
  ]);
  const org = new Map(rows(orgs).map((o) => [o.id, o.name]));
  const camp = new Map(rows(camps).map((c) => [c.id, c.title]));
  const now = isoToWibInput(new Date().toISOString());

  return (
    <div className="flex flex-col gap-6">
      <Alert tone="info">{t('finance.incomingHint')}</Alert>
      {open.length === 0 ? (
        <EmptyState icon="receipt_long" tone="success" title={t('finance.noInvoices')} />
      ) : (
        <Table card caption={t('finance.tabs.incoming')}>
          <THead>
            <TR>
              <TH>{t('finance.invoice')}</TH>
              <TH>{t('finance.org')}</TH>
              <TH align="right">{t('finance.amountDue')}</TH>
              <TH>{t('finance.due')}</TH>
              <TH align="right">{t('form.actions')}</TH>
            </TR>
          </THead>
          <TBody>
            {open.map((i) => (
              <TR key={i.id}>
                <TD>
                  <span className="font-mono text-caption font-semibold text-ink">{i.number}</span>
                  <span className="block text-caption text-muted">
                    {t(`finance.invoiceKind.${i.kind}`)}
                    {i.campaign_id ? ` · ${camp.get(i.campaign_id) ?? ''}` : ''}
                  </span>
                </TD>
                <TD muted>{org.get(i.org_id) ?? '—'}</TD>
                <TD numeric>
                  <span className="font-semibold">{idr(i.amount_due ?? i.total, loc)}</span>
                  {Number(i.credit_applied) > 0 ? (
                    <span className="block text-caption text-muted">
                      {t('finance.creditSplit', { total: idr(i.total, loc), credit: idr(i.credit_applied, loc) })}
                    </span>
                  ) : null}
                </TD>
                <TD muted>{i.due_at ? <RelativeTime value={i.due_at} locale={loc} /> : '—'}</TD>
                <TD align="right">
                  <ActionDialog
                    trigger={{ label: t('finance.confirm'), variant: 'ink', icon: 'payments' }}
                    title={t('finance.confirmTitle', { number: i.number ?? '' })}
                    description={Number(i.credit_applied) > 0 ? t('finance.confirmBodyCredit', { total: idr(i.total, loc), credit: idr(i.credit_applied, loc), due: idr(i.amount_due, loc) }) : t('finance.confirmBody', { total: idr(i.total, loc) })}
                    tone="ink"
                    submitLabel={t('finance.confirm')}
                    success={t('finance.confirmed')}
                    action={confirmInvoice.bind(null, i.id!)}
                    fields={[
                      { kind: 'text', name: 'amount', label: t('finance.amount'), required: true, defaultValue: String(i.amount_due ?? i.total ?? ''), prefix: 'Rp', helper: t('finance.amountHelp') },
                      { kind: 'datetime', name: 'paid_at', label: t('finance.paidAt'), required: true, defaultValue: now, helper: t('form.wib') },
                      { kind: 'text', name: 'ref', label: t('finance.ref'), required: true, maxLength: 100, helper: t('finance.refHelp') },
                      { kind: 'select', name: 'channel', label: t('finance.channel'), required: true, options: [{ value: 'transfer', label: t('finance.channels.transfer') }, { value: 'qris', label: t('finance.channels.qris') }] },
                    ]}
                  />
                </TD>
              </TR>
            ))}
          </TBody>
        </Table>
      )}
      {paid.length ? (
        <Card padding="md">
          <CardHeader>
            <CardTitle>{t('finance.recentPaid')}</CardTitle>
          </CardHeader>
          <ul className="mt-3 flex flex-col gap-1.5 text-body-s">
            {paid.map((i) => (
              <li key={i.id} className="flex flex-wrap justify-between gap-2">
                <span className="font-mono text-caption">{i.number}</span>
                <span className="text-text-2">{org.get(i.org_id) ?? '—'}</span>
                <span className="tnum font-semibold">{idr(i.paid_amount, loc)}</span>
                <span className="text-muted">{i.paid_at ? formatDateTime(i.paid_at, loc) : '—'}</span>
              </li>
            ))}
          </ul>
        </Card>
      ) : null}
    </div>
  );
}

async function Payouts({ loc, claims, batch }: { loc: UiLocale; claims: Claims; batch: string }) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  const [reqRes, holdRes, batchRes] = await Promise.all([
    db.from('payouts').select('id, user_id, amount, fee, created_at').eq('channel', 'batch').eq('status', 'requested').is('batch_id', null).order('created_at').limit(1000),
    db.from('payouts').select('id, user_id, amount, fee, channel, hold_reason, batch_id, created_at').eq('status', 'on_hold').order('created_at').limit(200),
    db.from('payout_batches').select('id, created_by, approved_by, status, cutoff_at, total, count, executed_at, created_at').order('created_at', { ascending: false }).limit(20),
  ]);
  const requested = rows(reqRes);
  const held = rows(holdRes);
  const batches = rows(batchRes);
  const byUser = new Map<string, number>();
  for (const p of requested) byUser.set(p.user_id!, (byUser.get(p.user_id!) ?? 0) + Number(p.amount ?? 0) - Number(p.fee ?? 0));
  const top = [...byUser.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10);
  const userIds = [...byUser.keys()];
  const [flagRes, user] = await Promise.all([
    userIds.length
      ? db.from('fraud_flags').select('id, target_type, target_id, signal, status').in('status', ['open', 'held']).in('target_id', [...userIds, ...requested.map((p) => p.id!)])
      : Promise.resolve({ data: [], error: null }),
    names(db, [...userIds, ...held.map((p) => p.user_id)]),
  ]);
  const flags = rows(flagRes);
  const flagged = new Set(flags.map((f) => f.target_id));
  const total = requested.reduce((s, p) => s + Number(p.amount ?? 0) - Number(p.fee ?? 0), 0);
  const selected = batches.find((b) => b.id === batch) ?? null;

  return (
    <div className="flex flex-col gap-6">
      <section className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <StatCard label={t('finance.requested')} value={String(requested.length)} icon="account_balance_wallet" />
        <StatCard label={t('finance.requestedTotal')} value={idr(total, loc)} icon="payments" variant="dark" />
        <StatCard label={t('finance.flagged')} value={String(flags.length)} icon="flag" variant={flags.length ? 'tint' : 'default'} />
        <StatCard label={t('finance.onHold')} value={String(held.length)} icon="hourglass_top" />
      </section>

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-2">
        <Card padding="md" className="flex flex-col gap-3">
          <CardHeader>
            <CardTitle>{t('finance.createBatch')}</CardTitle>
            <CardDescription>{t('finance.createBatchBody')}</CardDescription>
          </CardHeader>
          <ActionDialog
            trigger={{ label: t('finance.createBatch'), icon: 'add', variant: 'primary' }}
            title={t('finance.createBatch')}
            description={t('finance.createBatchBody')}
            submitLabel={t('finance.createBatch')}
            success={t('finance.batchCreated')}
            action={createBatch}
            fields={[{ kind: 'datetime', name: 'cutoff', label: t('finance.cutoff'), required: true, defaultValue: isoToWibInput(new Date().toISOString()), helper: t('form.wib') }]}
          />
        </Card>
        <Card padding="md" className="flex flex-col gap-2">
          <CardHeader>
            <CardTitle>{t('finance.topEarners')}</CardTitle>
          </CardHeader>
          {top.length === 0 ? <p className="text-body-s text-muted">—</p> : null}
          <ol className="flex flex-col gap-1 text-body-s">
            {top.map(([uid, sum]) => (
              <li key={uid} className="flex items-center justify-between gap-2">
                <Link href={`/users?user=${uid}`} className="font-semibold text-link hover:underline">
                  @{user.get(uid) ?? uid.slice(0, 8)}
                </Link>
                <span className="flex items-center gap-2">
                  {flagged.has(uid) ? <Badge tone="danger" size="sm" icon="flag">{t('finance.flag')}</Badge> : null}
                  <span className="tnum font-semibold">{idr(sum, loc)}</span>
                </span>
              </li>
            ))}
          </ol>
        </Card>
      </div>

      <Table card caption={t('finance.batches')}>
        <THead>
          <TR>
            <TH>{t('finance.batch')}</TH>
            <TH>{t('finance.status')}</TH>
            <TH align="right">{t('finance.count')}</TH>
            <TH align="right">{t('finance.total')}</TH>
            <TH>{t('finance.cutoff')}</TH>
          </TR>
        </THead>
        <TBody>
          {batches.map((b) => (
            <TR key={b.id} selected={b.id === batch} interactive>
              <TD>
                <Link href={`/finance?tab=payout&batch=${b.id}`} className="font-mono text-caption font-semibold text-ink hover:text-link focus-ring">
                  {b.id!.slice(0, 8)}
                </Link>
                {b.created_by === claims.sub ? <Badge tone="outline" size="sm" className="ml-2">{t('finance.mine')}</Badge> : null}
              </TD>
              <TD>
                <Badge tone={b.status === 'closed' || b.status === 'paid' ? 'success' : b.status === 'draft' ? 'neutral' : 'primary'}>{t(`finance.batchStatus.${b.status}`)}</Badge>
              </TD>
              <TD numeric>{b.count}</TD>
              <TD numeric>{idr(b.total, loc)}</TD>
              <TD muted>{b.cutoff_at ? formatDateTime(b.cutoff_at, loc) : '—'}</TD>
            </TR>
          ))}
          {batches.length === 0 ? (
            <TR>
              <TD colSpan={5} muted>
                {t('finance.noBatches')}
              </TD>
            </TR>
          ) : null}
        </TBody>
      </Table>

      {selected && isUuid(selected.id) ? <BatchDetail b={selected} loc={loc} me={claims.sub} /> : null}

      {held.length ? (
        <Card padding="md" className="flex flex-col gap-3">
          <CardHeader>
            <CardTitle>{t('finance.heldTitle')}</CardTitle>
            <CardDescription>{t('finance.heldBody')}</CardDescription>
          </CardHeader>
          <ul className="flex flex-col divide-y divide-border">
            {held.map((p) => (
              <li key={p.id} className="flex flex-wrap items-center gap-3 py-2 text-body-s">
                <span className="font-semibold text-ink">@{user.get(p.user_id!) ?? '—'}</span>
                <span className="tnum">{idr(Number(p.amount) - Number(p.fee), loc)}</span>
                <Badge tone="warn" size="sm">{t.has(`export.reasons.${p.hold_reason}`) ? t(`export.reasons.${p.hold_reason}`) : p.hold_reason}</Badge>
                <span className="ml-auto">
                  <CancelPayout id={p.id!} t={t} />
                </span>
              </li>
            ))}
          </ul>
        </Card>
      ) : null}
    </div>
  );
}

function CancelPayout({ id, t }: { id: string; t: Awaited<ReturnType<typeof getTranslations>> }) {
  return (
    <ActionDialog
      trigger={{ label: t('finance.cancelPayout'), variant: 'ghost', icon: 'cancel' }}
      title={t('finance.cancelPayout')}
      description={t('finance.cancelPayoutBody')}
      tone="danger"
      submitLabel={t('finance.cancelPayout')}
      success={t('finance.payoutCancelled')}
      action={cancelPayout.bind(null, id)}
      fields={[{ kind: 'textarea', name: 'reason', label: t('form.reason'), required: true, maxLength: 500 }]}
    />
  );
}

async function BatchDetail({ b, loc, me }: { b: { id: string | null; status: string | null; created_by: string | null; approved_by: string | null; count: number | null; total: number | null }; loc: UiLocale; me: string }) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  const payouts = rows(await db.from('payouts').select('id, user_id, amount, fee, status, hold_reason, bank_ref, last_error').eq('batch_id', b.id!).order('created_at'));
  const user = await names(db, payouts.map((p) => p.user_id));
  const id = b.id!;
  return (
    <Card padding="md" className="flex flex-col gap-4">
      <CardHeader>
        <CardTitle>
          {t('finance.batch')} <span className="font-mono">{id.slice(0, 8)}</span> · {t(`finance.batchStatus.${b.status}`)}
        </CardTitle>
        <CardDescription>{t(`finance.batchStep.${b.status}`)}</CardDescription>
      </CardHeader>
      {b.status === 'draft' ? (
        b.created_by === me ? (
          <Alert tone="info">{t('finance.needSecondPerson')}</Alert>
        ) : (
          <div>
            <ActionButton label={t('finance.approveBatch')} icon="verified" variant="primary" success={t('finance.batchApproved')} action={approveBatch.bind(null, id)} />
          </div>
        )
      ) : null}
      {/* Satu slot untuk export & unduh ulang: setelah export, revalidasi mengganti status ke exported tanpa membuang hasil panel. */}
      {b.status === 'approved' || b.status === 'exported' ? (
        <ExportPanel
          label={b.status === 'approved' ? t('finance.exportCsv') : t('finance.downloadAgain')}
          itemsTitle={t('finance.heldInExport')}
          action={exportPayoutCsv.bind(null, id, b.status === 'approved' ? 0 : (b.count ?? 0))}
        />
      ) : null}
      {b.status === 'exported' ? (
        <BatchResults
          batchId={id}
          payouts={payouts.filter((p) => p.status === 'processing').map((p) => ({ id: p.id!, username: user.get(p.user_id!) ?? '—', net: Number(p.amount) - Number(p.fee) }))}
        />
      ) : null}
      {b.status === 'paid' ? (
        <div>
          <ActionDialog
            trigger={{ label: t('finance.uploadProof'), icon: 'upload', variant: 'primary' }}
            title={t('finance.uploadProof')}
            description={t('finance.uploadProofBody')}
            submitLabel={t('finance.upload')}
            success={t('finance.proofUploaded')}
            action={uploadProof.bind(null, 'batch', id)}
            fields={[{ ...PROOF, label: t('finance.proofFile'), helper: t('finance.proofHelp') }]}
          />
        </div>
      ) : null}
      <Table dense>
        <THead>
          <TR>
            <TH>{t('finance.payout')}</TH>
            <TH align="right">{t('finance.net')}</TH>
            <TH>{t('finance.status')}</TH>
            <TH>{t('finance.bankRef')}</TH>
            {b.status === 'draft' ? <TH align="right">{t('form.actions')}</TH> : null}
          </TR>
        </THead>
        <TBody>
          {payouts.map((p) => (
            <TR key={p.id}>
              <TD>@{user.get(p.user_id!) ?? '—'}</TD>
              <TD numeric>{idr(Number(p.amount) - Number(p.fee), loc)}</TD>
              <TD>
                <StatusBadge kind="payout" status={p.status!} label={t(`status.payout.${p.status}`)} />
                {p.hold_reason ? <span className="ml-2 text-caption text-muted">{p.hold_reason}</span> : null}
                {p.last_error ? <span className="block text-caption text-danger-fg">{p.last_error}</span> : null}
              </TD>
              <TD muted className="font-mono text-caption">{p.bank_ref ?? '—'}</TD>
              {b.status === 'draft' ? (
                <TD align="right">
                  {p.status === 'requested' ? <CancelPayout id={p.id!} t={t} /> : null}
                </TD>
              ) : null}
            </TR>
          ))}
        </TBody>
      </Table>
    </Card>
  );
}

async function Instant({ loc }: { loc: UiLocale }) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  const list = rows(await db.from('payouts').select('id, user_id, amount, fee, status, provider_ref, last_error, created_at, paid_at').eq('channel', 'instant').in('status', ['requested', 'processing', 'failed']).order('created_at').limit(200));
  const user = await names(db, list.map((p) => p.user_id));
  return (
    <div className="flex flex-col gap-4">
      <Alert tone="info">{t('finance.instantHint')}</Alert>
      {list.length === 0 ? (
        <EmptyState icon="bolt" tone="success" title={t('finance.noInstant')} />
      ) : (
        <Table card caption={t('finance.tabs.instant')}>
          <THead>
            <TR>
              <TH>{t('finance.payout')}</TH>
              <TH align="right">{t('finance.net')}</TH>
              <TH>{t('finance.status')}</TH>
              <TH>{t('finance.providerRef')}</TH>
              <TH align="right">{t('finance.age')}</TH>
            </TR>
          </THead>
          <TBody>
            {list.map((p) => (
              <TR key={p.id}>
                <TD>
                  <Link href={`/users?user=${p.user_id}`} className="font-semibold text-link hover:underline">
                    @{user.get(p.user_id!) ?? '—'}
                  </Link>
                  <code className="block font-mono text-[11px] text-muted">{p.id}</code>
                </TD>
                <TD numeric>{idr(Number(p.amount) - Number(p.fee), loc)}</TD>
                <TD>
                  <StatusBadge kind="payout" status={p.status!} label={t(`status.payout.${p.status}`)} />
                  {p.last_error ? <span className="block max-w-xs text-caption break-words text-danger-fg">{p.last_error}</span> : null}
                </TD>
                <TD muted className="font-mono text-caption break-all">{p.provider_ref ?? t('finance.noProviderRef')}</TD>
                <TD align="right" muted>
                  <RelativeTime value={p.created_at!} locale={loc} />
                </TD>
              </TR>
            ))}
          </TBody>
        </Table>
      )}
    </div>
  );
}

async function Refunds({ loc, me }: { loc: UiLocale; me: string }) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  const list = rows(await db.from('org_refunds').select('id, org_id, campaign_id, amount, transfer_fee, status, requested_by, created_at, paid_at').in('status', ['requested', 'approved', 'paid']).order('created_at', { ascending: false }).limit(100));
  const [orgs, camps] = await Promise.all([
    db.from('organizations').select('id, name').in('id', uniq(list.map((r) => r.org_id))),
    db.from('campaigns').select('id, title').in('id', uniq(list.map((r) => r.campaign_id))),
  ]);
  const org = new Map(rows(orgs).map((o) => [o.id, o.name]));
  const camp = new Map(rows(camps).map((c) => [c.id, c.title]));
  return (
    <div className="flex flex-col gap-4">
      <Alert tone="info">{t('finance.refundHint')}</Alert>
      {list.length === 0 ? (
        <EmptyState icon="undo" tone="success" title={t('finance.noRefunds')} />
      ) : (
        <Table card caption={t('finance.tabs.refund')}>
          <THead>
            <TR>
              <TH>{t('finance.org')}</TH>
              <TH align="right">{t('finance.amount')}</TH>
              <TH align="right">{t('finance.transferFee')}</TH>
              <TH>{t('finance.status')}</TH>
              <TH align="right">{t('form.actions')}</TH>
            </TR>
          </THead>
          <TBody>
            {list.map((r) => (
              <TR key={r.id}>
                <TD>
                  <span className="font-semibold text-ink">{org.get(r.org_id) ?? '—'}</span>
                  <span className="block text-caption text-muted">{r.campaign_id ? camp.get(r.campaign_id) : '—'}</span>
                </TD>
                <TD numeric>{idr(r.amount, loc)}</TD>
                <TD numeric muted>{idr(r.transfer_fee, loc)}</TD>
                <TD>
                  <Badge tone={r.status === 'paid' ? 'success' : r.status === 'approved' ? 'primary' : 'warn'}>{t(`finance.refundStatus.${r.status}`)}</Badge>
                </TD>
                <TD align="right">
                  {r.status === 'requested' && r.requested_by === me ? (
                    <span className="inline-flex flex-col items-end gap-1">
                      <Button size="sm" iconLeft="verified" disabled>
                        {t('finance.approveRefund')}
                      </Button>
                      <span className="text-caption text-muted">{t('finance.refundOwn')}</span>
                    </span>
                  ) : r.status === 'requested' ? (
                    <ActionButton label={t('finance.approveRefund')} icon="verified" variant="primary" success={t('finance.refundApproved')} action={approveRefund.bind(null, r.id!)} />
                  ) : r.status === 'approved' ? (
                    <ActionDialog
                      trigger={{ label: t('finance.uploadProof'), icon: 'upload', variant: 'ink' }}
                      title={t('finance.uploadProof')}
                      description={t('finance.refundProofBody', { amount: idr(Number(r.amount) - Number(r.transfer_fee), loc) })}
                      tone="ink"
                      submitLabel={t('finance.upload')}
                      success={t('finance.refundPaid')}
                      action={uploadProof.bind(null, 'refund', r.id!)}
                      fields={[{ ...PROOF, label: t('finance.proofFile'), helper: t('finance.proofHelp') }]}
                    />
                  ) : (
                    <span className="text-caption text-muted">{r.paid_at ? formatDateTime(r.paid_at, loc) : ''}</span>
                  )}
                </TD>
              </TR>
            ))}
          </TBody>
        </Table>
      )}
    </div>
  );
}

async function Pph21() {
  const t = await getTranslations('admin');
  const now = new Date();
  const from = isoToWibDate(new Date(now.getFullYear(), now.getMonth() - 1, 1, 12));
  const to = isoToWibDate(new Date(now.getFullYear(), now.getMonth(), 0, 12));
  return (
    <Card padding="md" className="flex flex-col gap-4">
      <CardHeader>
        <CardTitle>{t('finance.pph21')}</CardTitle>
        <CardDescription>{t('finance.pph21Body')}</CardDescription>
      </CardHeader>
      <ExportPanel
        label={t('finance.exportPph21')}
        itemsTitle={t('finance.missingKyc')}
        action={exportPph21}
        form={
          <>
            <Field label={t('finance.from')} className="sm:w-48">
              <Input type="date" name="from" defaultValue={from} required />
            </Field>
            <Field label={t('finance.to')} className="sm:w-48">
              <Input type="date" name="to" defaultValue={to} required />
            </Field>
          </>
        }
      />
    </Card>
  );
}
