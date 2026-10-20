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
import { CreditCard } from '@/features/billing/credit-card';
import { creditCap, parseCredit } from '@/features/billing/credit';
import { LeftoverPanel, type LeftoverRow } from '@/features/billing/leftover-panel';
import { InvoiceCredit } from '@/features/billing/pay-credit';
import { RefundDestDialog, type RefundDestConfig } from '@/features/billing/refund-dest';
import { can, getOrgContext, isUuid, num, publicSettings } from '@/lib/org';

const PAGE = 25;
const INVOICE_COLS = 'id, number, kind, campaign_id, subtotal, mgmt_fee, admin_fee, service_fee, tax, total, credit_applied, fee_exempt, amount_due, status, payment_channel, paid_amount, paid_at, faktur_no, faktur_path, issued_at, due_at, pin_until';

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
  credit_applied: num(r.credit_applied),
  fee_exempt: num(r.fee_exempt),
  amount_due: r.amount_due == null ? num(r.total) - num(r.credit_applied) : num(r.amount_due),
  status: String(r.status ?? 'issued'),
  payment_channel: (r.payment_channel as string | null) ?? null,
  paid_amount: r.paid_amount == null ? null : num(r.paid_amount),
  paid_at: (r.paid_at as string | null) ?? null,
  faktur_no: (r.faktur_no as string | null) ?? null,
  faktur_path: (r.faktur_path as string | null) ?? null,
  issued_at: (r.issued_at as string | null) ?? null,
  due_at: (r.due_at as string | null) ?? null,
  pin_until: (r.pin_until as string | null) ?? null,
});

export default async function BillingPage({ params, searchParams }: { params: Promise<{ org: string }>; searchParams: Promise<{ invoice?: string; page?: string }> }) {
  const [{ org: orgId }, sp] = await Promise.all([params, searchParams]);
  const { core, org, role, direct, claims } = await getOrgContext(orgId);
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
  const [list, selectedRes, settings, { data: refunds }, creditRes] = await Promise.all([
    core.from('invoices').select(INVOICE_COLS, { count: 'exact' }).eq('org_id', orgId).order('issued_at', { ascending: false }).range((page - 1) * PAGE, page * PAGE - 1),
    selectedId ? core.from('invoices').select(INVOICE_COLS).eq('id', selectedId).eq('org_id', orgId).maybeSingle() : null,
    publicSettings(core, ['public.billing.qris_max_idr', 'public.billing.qris_payload', 'public.billing.bank_account', 'public.finance.refund_transfer_fee_idr']),
    core.from('org_refunds').select('id, campaign_id, amount, transfer_fee, status, created_at, paid_at, dest_bank, dest_account, dest_set_by').eq('org_id', orgId).order('created_at', { ascending: false }).limit(50),
    core.rpc('org_credit', { p_org: orgId }),
  ]);
  const invoices = (list.data ?? []).filter((r) => r.id).map((r) => asInvoice(r as Record<string, unknown>));
  const selected = selectedRes?.data?.id ? asInvoice(selectedRes.data as Record<string, unknown>) : null;
  const fakturUrl = selected?.faktur_path ? ((await core.storage.from('invoice-docs').createSignedUrl(selected.faktur_path, 600)).data?.signedUrl ?? null) : null;
  const credit = creditRes.error ? null : parseCredit(creditRes.data);
  const leftover: LeftoverRow[] = (credit?.leftovers ?? []).map((l) => ({ campaignId: l.campaignId, title: l.title, leftover: l.amount }));
  const aal2 = claims.aal === 'aal2';

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
  const ownerDirect = direct && role === 'brand_owner';
  const destConfig: RefundDestConfig = {
    kind: org.org_type === 'perorangan' ? 'perorangan' : 'badan',
    legalName: org.legal_name ?? '',
    ownerDirect,
    methodsHref: `${hosts.accounts}/payout-methods?next=${encodeURIComponent(`${hosts.brand}${base}`)}`,
  };

  return (
    <>
      <PageHeader title={t('billing.title')} description={t('billing.description')} />
      <div className="flex flex-col gap-5">
        {selected ? (
          <InvoiceDetail
            invoice={selected}
            campaignTitle={selected.campaign_id ? (titleOf.get(selected.campaign_id) ?? null) : null}
            orgId={orgId}
            pay={pay}
            fakturUrl={fakturUrl}
            creditAction={
              selected.status === 'issued' && (creditCap(credit, selected) > 0 || selected.credit_applied > 0) ? (
                <InvoiceCredit
                  key={`${selected.id}:${selected.credit_applied}:${creditCap(credit, selected)}`}
                  orgId={orgId}
                  invoiceId={selected.id}
                  number={selected.number}
                  total={selected.total}
                  applied={selected.credit_applied}
                  cap={creditCap(credit, selected)}
                  aal2={aal2}
                  securityHref={securityUrl(`${hosts.brand}${base}?invoice=${selected.id}`)}
                />
              ) : undefined
            }
          />
        ) : null}

        {credit && (credit.balance > 0 || credit.reserved > 0 || credit.history.length) ? <CreditCard credit={credit} /> : null}

        {leftover.length ? (
          <LeftoverPanel
            orgId={orgId}
            rows={leftover}
            aal2={aal2}
            securityHref={securityUrl(`${hosts.brand}${base}`)}
            refundFee={num(settings['public.finance.refund_transfer_fee_idr'])}
            dest={destConfig}
          />
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
                    <TD numeric className="font-semibold">
                      {formatIDR(i.total, { locale: loc, fractionDigits: Number.isInteger(i.total) ? 0 : 2 })}
                      {i.status === 'issued' && i.credit_applied > 0 ? (
                        <span className="block text-caption font-normal text-muted">
                          {t('billing.dueShort', { amount: formatIDR(i.amount_due, { locale: loc, fractionDigits: Number.isInteger(i.amount_due) ? 0 : 2 }) })}
                        </span>
                      ) : null}
                    </TD>
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
                    <span className="flex flex-col items-start gap-1">
                      <Badge tone={r.status === 'paid' ? 'success' : r.status === 'cancelled' ? 'neutral' : 'warn'}>{t(`billing.refundStatus.${r.status ?? 'requested'}`)}</Badge>
                      {r.dest_account ? (
                        <span className="text-caption text-muted">{t('refundDest.summary', { bank: r.dest_bank ?? '', last4: r.dest_account.slice(-4) })}</span>
                      ) : r.dest_set_by ? (
                        <span className="text-caption text-muted">{t('refundDest.summaryOwner')}</span>
                      ) : r.status === 'requested' && r.id && aal2 ? (
                        <RefundDestDialog orgId={orgId} refundId={r.id} config={destConfig} />
                      ) : null}
                    </span>
                  </TD>
                  <TD muted>{r.created_at ? formatDate(r.created_at, loc) : '—'}</TD>
                </TR>
              ))
            )}
          </TBody>
        </Table>
      </div>
    </>
  );
}
