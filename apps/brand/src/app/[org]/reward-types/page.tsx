import type { Metadata } from 'next';
import { getLocale, getTranslations } from 'next-intl/server';
import { Alert, Badge, Button, Card, EmptyState, PageHeader, Table, TBody, TD, TH, THead, TR, formatIDR, formatNumber } from '@clipper/ui';
import { CodesDialog } from '@/features/reward-types/codes-dialog';
import { RewardTypeDialog, type RewardTypeRow } from '@/features/reward-types/reward-type-dialog';
import { can, getOrgContext, num } from '@/lib/org';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('brand.nav'))('rewardTypes') };
}

const schemaOf = (v: unknown): RewardTypeRow['recipient_schema'] =>
  (Array.isArray(v) ? v : []).flatMap((f) =>
    f && typeof f === 'object' && typeof (f as { key?: unknown }).key === 'string'
      ? [{
          key: (f as { key: string }).key,
          label: String((f as { label?: unknown }).label ?? (f as { key: string }).key),
          pii: (f as { pii?: unknown }).pii === true,
          required: (f as { required?: unknown }).required !== false,
        }]
      : [],
  );

export default async function RewardTypesPage({ params }: { params: Promise<{ org: string }> }) {
  const { org: orgId } = await params;
  const { core, role } = await getOrgContext(orgId);
  const [t, locale, { data }] = await Promise.all([
    getTranslations('brand.rewardTypes'),
    getLocale(),
    core
      .from('reward_types')
      .select('id, owner_org_id, code, name, kind, unit_label, idr_value_per_unit, decimals, fulfillment, recipient_schema, stock')
      .or(`owner_org_id.is.null,owner_org_id.eq.${orgId}`)
      .order('code'),
  ]);
  const loc = locale === 'en' ? 'en' : 'id';
  const edit = can(role, 'edit');
  const rows = (data ?? []).flatMap((r) =>
    r.id && r.code
      ? [{
          global: r.owner_org_id == null,
          row: {
            id: r.id,
            code: r.code,
            name: r.name ?? r.code,
            kind: r.kind ?? 'custom',
            unit_label: r.unit_label ?? '',
            idr_value_per_unit: num(r.idr_value_per_unit),
            decimals: r.decimals ?? 0,
            fulfillment: r.fulfillment ?? 'manual_export',
            recipient_schema: schemaOf(r.recipient_schema),
            stock: r.stock == null ? null : num(r.stock),
          } satisfies RewardTypeRow,
        }]
      : [],
  );
  const own = rows.filter((r) => !r.global).map((r) => r.row);
  const global = rows.filter((r) => r.global).map((r) => r.row);
  const pools = own.filter((r) => r.fulfillment === 'code_pool');
  const available = new Map<string, number>();
  if (edit) {
    await Promise.all(
      pools.map(async (r) => {
        const { count } = await core.from('reward_codes').select('id', { count: 'exact', head: true }).eq('reward_type_id', r.id).is('fulfillment_id', null);
        available.set(r.id, count ?? 0);
      }),
    );
  }
  const value = (r: RewardTypeRow) => formatIDR(r.idr_value_per_unit, { locale: loc, fractionDigits: Number.isInteger(r.idr_value_per_unit) ? 0 : 2 });

  return (
    <>
      <PageHeader
        title={t('title')}
        description={t('description')}
        actions={edit ? <RewardTypeDialog orgId={orgId} trigger={<Button iconLeft="add">{t('create')}</Button>} /> : null}
      />
      {!edit ? <Alert tone="info" className="mb-4">{t('readOnly')}</Alert> : null}
      {own.length === 0 ? (
        <Card padding="lg" className="mb-5">
          <EmptyState icon="redeem" title={t('emptyTitle')} body={t('emptyBody')} />
        </Card>
      ) : (
        <ul className="mb-6 grid gap-3 lg:grid-cols-2">
          {own.map((r) => (
            <li key={r.id}>
              <Card className="flex h-full flex-col gap-3">
                <div className="flex items-start gap-3">
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-h6 text-ink">{r.name}</p>
                    <p className="flex flex-wrap gap-1.5 pt-1">
                      <Badge size="sm" tone="outline" className="font-mono">{r.code}</Badge>
                      <Badge size="sm">{t(`kinds.${r.kind}`)}</Badge>
                      <Badge size="sm" tone="primary">{t(`fulfillments.${r.fulfillment}`)}</Badge>
                    </p>
                  </div>
                  {edit ? <RewardTypeDialog orgId={orgId} row={r} trigger={<Button variant="ghost" size="sm" iconLeft="edit">{t('edit')}</Button>} /> : null}
                </div>
                <dl className="grid grid-cols-2 gap-2 text-body-s sm:grid-cols-3">
                  <div>
                    <dt className="text-muted">{t('perUnit', { unit: r.unit_label })}</dt>
                    <dd className="font-semibold text-ink tnum">{value(r)}</dd>
                  </div>
                  <div>
                    <dt className="text-muted">{t('stock')}</dt>
                    <dd className="font-semibold text-ink tnum">{r.stock == null ? t('unlimited') : formatNumber(r.stock, loc, { maximumFractionDigits: r.decimals })}</dd>
                  </div>
                  {r.fulfillment === 'code_pool' && edit ? (
                    <div>
                      <dt className="text-muted">{t('codesAvailable')}</dt>
                      <dd className="font-semibold text-ink tnum">{formatNumber(available.get(r.id) ?? 0, loc)}</dd>
                    </div>
                  ) : null}
                </dl>
                {r.recipient_schema.length ? (
                  <p className="text-caption text-muted">
                    {t('fieldsList', { fields: r.recipient_schema.map((f) => (f.pii ? `${f.label} (${t('pii')})` : f.label)).join(', ') })}
                  </p>
                ) : null}
                {r.fulfillment === 'code_pool' && edit ? (
                  <div className="mt-auto">
                    <CodesDialog orgId={orgId} rewardTypeId={r.id} name={r.name} />
                  </div>
                ) : null}
              </Card>
            </li>
          ))}
        </ul>
      )}
      {global.length ? (
        <Table caption={t('globalTitle')} captionVisible>
          <THead>
            <TR>
              <TH>{t('name')}</TH>
              <TH>{t('code')}</TH>
              <TH align="right">{t('idrValue')}</TH>
            </TR>
          </THead>
          <TBody>
            {global.map((r) => (
              <TR key={r.id}>
                <TD>{r.name}</TD>
                <TD><Badge size="sm" tone="outline" className="font-mono">{r.code}</Badge></TD>
                <TD numeric>{value(r)} / {r.unit_label}</TD>
              </TR>
            ))}
          </TBody>
        </Table>
      ) : null}
    </>
  );
}
