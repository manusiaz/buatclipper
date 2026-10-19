import Link from 'next/link';
import type { Metadata } from 'next';
import { getLocale, getTranslations } from 'next-intl/server';
import { hosts, securityUrl } from '@clipper/auth';
import {
  Badge,
  Card,
  EmptyState,
  PageHeader,
  Pagination,
  Table,
  TBody,
  TD,
  TH,
  THead,
  TR,
  formatDate,
  formatIDR,
} from '@clipper/ui';
import { InvoiceDetail, invoiceTone, type InvoiceRow, type PaymentConfig } from '@/features/billing/invoice-detail';
import { LeftoverPanel, type LeftoverRow } from '@/features/billing/leftover-panel';
import { can, getOrgContext, isUuid, num, publicSettings } from '@/lib/org';

const PAGE = 25;
const INVOICE_COLS = 'id, number, kind, campaign_id, subtotal, mgmt_fee, admin_fee, service_fee, tax, total, status, payment_channel, paid_amount, paid_at, faktur_no, issued_at, due_at, pin_until';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('brand.nav'))('billing') };
}

const asInvoice = (r: Record<string, unknown>): InvoiceRow => ({
  id: String(r.id),
  number: String(r.number ?? ''),
  kind: String(r.kind ?? 'campaign'),
  campaign_id: (r.campaign_id as string | null) ?? null,
  subtotal: num(r.subtotal),
  mgmt_fee: num(r.mgmt_fee),
  admin_fee: num(r.admin_fee),
  service_fee: num(r.service_fee),
  tax: num(r.tax),
  total: num(r.total),
  status: String(r.status ?? 'issued'),
  payment_channel: (r.payment_channel as string | null) ?? null,
  paid_amount: r.paid_amount == null ? null : num(r.paid_amount),
  paid_at: (r.paid_at as string | null) ?? null,
  faktur_no: (r.faktur_no as string | null) ?? null,
  issued_at: (r.issued_at as string | null) ?? null,
  due_at: (r.due_at as string | null) ?? null,
  pin_until: (r.pin_until as string | null) ?? null,
});

export default async function BillingPage({ params, searchParams }: { params: Promise<{ org: string }>; searchParams: Promise<{ invoice?: string; page?: string }> }) {
  const [{ org: orgId }, sp] = await Promise.all([params, searchParams]);
  const { core, role, claims } = await getOrgContext(orgId);
  const [t, locale] = await Promise.all([getTranslations('brand'), getLocale()]);
  const loc = locale === 'en' ? 'en' : 'id';
  if (!can(role, 'billing')) {
    return (
      <>
        <PageHeader title={t('billing.title')} />
        <Card padding="lg"><EmptyState icon="lock" title={t('billing.noAccessTitle')} body={t('billing.noAccessBody')} /></Card>
      </>
    );
  }

  const page = Math.max(1, Number.parseInt(sp.page ?? '1', 10) || 1);
  const selectedId = isUuid(sp.invoice) ? sp.invoice : null;
  const [list, selectedRes, settings, { data: refunds }, { data: settled }, { data: idrType }] = await Promise.all([
    core.from('invoices').select(INVOICE_COLS, { count: 'exact' }).eq('org_id', orgId).order('issued_at', { ascending: false }).range((page - 1) * PAGE, page * PAGE - 1),
    selectedId ? core.from('invoices').select(INVOICE_COLS).eq('id', selectedId).eq('org_id', orgId).maybeSingle() : null,
    publicSettings(core, ['public.billing.qris_max_idr', 'public.billing.qris_payload', 'public.billing.bank_account']),
    core.from('org_refunds').select('id, campaign_id, amount, transfer_fee, status, created_at, paid_at').eq('org_id', orgId).order('created_at', { ascending: false }).limit(50),
    core.from('campaigns').select('id, title').eq('org_id', orgId).eq('status', 'settled').eq('is_template', false),
    core.from('reward_types').select('id').eq('code', 'IDR').is('owner_org_id', null).maybeSingle(),
  ]);
  const invoices = (list.data ?? []).filter((r) => r.id).map((r) => asInvoice(r as Record<string, unknown>));
  const selected = selectedRes?.data?.id ? asInvoice(selectedRes.data as Record<string, unknown>) : null;

  // Sisa budget campaign settled: sisa pool Rupiah − refund yang sudah diajukan (rollover tidak terlihat dari api; DB tetap mengecek ledger).
  const settledIds = (settled ?? []).map((c) => c.id).filter(isUuid);
  const { data: pools } = settledIds.length && idrType?.id
    ? await core.from('reward_pools').select('campaign_id, remaining').in('campaign_id', settledIds).eq('reward_type_id', idrType.id)
    : { data: [] };
  const refunded = new Map<string, number>();
  for (const r of refunds ?? []) if (r.campaign_id && r.status !== 'cancelled') refunded.set(r.campaign_id, (refunded.get(r.campaign_id) ?? 0) + num(r.amount));
  const leftover: LeftoverRow[] = (settled ?? []).flatMap((c) => {
    const rest = (pools ?? []).filter((p) => p.campaign_id === c.id).reduce((s, p) => s + num(p.remaining), 0) - (refunded.get(c.id ?? '') ?? 0);
    return c.id && rest >= 1 ? [{ campaignId: c.id, title: c.title ?? '', leftover: rest }] : [];
  });

  const campaignIds = [...new Set([...invoices, ...(selected ? [selected] : [])].map((i) => i.campaign_id).concat((refunds ?? []).map((r) => r.campaign_id)).filter(isUuid))];
  const { data: titles } = campaignIds.length ? await core.from('campaigns').select('id, title').in('id', campaignIds) : { data: [] };
  const titleOf = new Map((titles ?? []).map((c) => [c.id, c.title ?? '']));
  const bank = (settings['public.billing.bank_account'] ?? {}) as Partial<PaymentConfig['bank']>;
  const pay: PaymentConfig = {
    qrisMax: num(settings['public.billing.qris_max_idr'], 10_000_000),
    qrisPayload: typeof settings['public.billing.qris_payload'] === 'string' ? (settings['public.billing.qris_payload'] as string) : '',
    bank: { bank: bank.bank ?? '', number: bank.number ?? '', name: bank.name ?? '' },
  };
  const pageCount = Math.max(1, Math.ceil((list.count ?? 0) / PAGE));
  const base = `/${orgId}/billing`;

  return (
    <>
      <PageHeader title={t('billing.title')} description={t('billing.description')} />
      <div className="flex flex-col gap-5">
        {selected ? <InvoiceDetail invoice={selected} campaignTitle={selected.campaign_id ? (titleOf.get(selected.campaign_id) ?? null) : null} orgId={orgId} pay={pay} /> : null}

        {leftover.length ? (
          <LeftoverPanel orgId={orgId} rows={leftover} aal2={claims.aal === 'aal2'} securityHref={securityUrl(`${hosts.brand}${base}`)} />
        ) : null}

        {invoices.length === 0 ? (
          <Card padding="lg"><EmptyState icon="receipt_long" title={t('billing.emptyTitle')} body={t('billing.emptyBody')} /></Card>
        ) : (
          <Table
            caption={t('billing.invoices')}
            captionVisible
            footer={
              pageCount > 1 ? (
                <Pagination
                  page={page}
                  pageCount={pageCount}
                  linkAs={Link}
                  getHref={(p) => `${base}?page=${p}`}
                  labels={{ nav: t('common.pagination'), previous: t('common.previous'), next: t('common.next') }}
                />
              ) : undefined
            }
          >
            <THead>
              <TR>
                <TH>{t('billing.colNumber')}</TH>
                <TH>{t('billing.colKind')}</TH>
                <TH align="right">{t('billing.colTotal')}</TH>
                <TH>{t('billing.colStatus')}</TH>
                <TH>{t('billing.colDue')}</TH>
              </TR>
            </THead>
            <TBody>
              {invoices.map((i) => {
                const st = invoiceTone(i);
                return (
                  <TR key={i.id} selected={i.id === selected?.id}>
                    <TD>
                      <Link href={`${base}?invoice=${i.id}#invoice`} className="font-mono font-bold text-link focus-ring rounded-[4px]">{i.number}</Link>
                    </TD>
                    <TD>
                      <span className="flex max-w-[280px] flex-col">
                        <span className="text-ink">{t(`billing.kind.${i.kind}`)}</span>
                        {i.campaign_id ? <span className="truncate text-caption text-muted">{titleOf.get(i.campaign_id)}</span> : null}
                      </span>
                    </TD>
                    <TD numeric className="font-semibold">{formatIDR(i.total, { locale: loc, fractionDigits: Number.isInteger(i.total) ? 0 : 2 })}</TD>
                    <TD><Badge tone={st.tone}>{t(`billing.status.${st.key}`)}</Badge></TD>
                    <TD muted>{i.due_at ? formatDate(i.due_at, loc) : '—'}</TD>
                  </TR>
                );
              })}
            </TBody>
          </Table>
        )}

        <Table caption={t('billing.refunds')} captionVisible>
          <THead>
            <TR>
              <TH>{t('billing.colCampaign')}</TH>
              <TH align="right">{t('billing.colAmount')}</TH>
              <TH align="right">{t('billing.colFee')}</TH>
              <TH>{t('billing.colStatus')}</TH>
              <TH>{t('billing.colRequested')}</TH>
            </TR>
          </THead>
          <TBody>
            {(refunds ?? []).length === 0 ? (
              <TR>
                <TD colSpan={5} muted className="text-center">{t('billing.noRefunds')}</TD>
              </TR>
            ) : (
              (refunds ?? []).map((r) => (
                <TR key={r.id}>
                  <TD><span className="block max-w-[280px] truncate">{r.campaign_id ? titleOf.get(r.campaign_id) : '—'}</span></TD>
                  <TD numeric>{formatIDR(num(r.amount), { locale: loc })}</TD>
                  <TD numeric muted>{formatIDR(num(r.transfer_fee), { locale: loc })}</TD>
                  <TD>
                    <Badge tone={r.status === 'paid' ? 'success' : r.status === 'cancelled' ? 'neutral' : 'warn'}>{t(`billing.refundStatus.${r.status ?? 'requested'}`)}</Badge>
                  </TD>
                  <TD muted>{r.created_at ? formatDate(r.created_at, loc) : '—'}</TD>
                </TR>
              ))
            )}
          </TBody>
        </Table>
        <p className="text-caption text-muted">{t('billing.creditGap')}</p>
      </div>
    </>
  );
}
