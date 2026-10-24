import type { Metadata } from 'next';
import { getLocale, getTranslations } from 'next-intl/server';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import { Badge, Card, CardDescription, CardHeader, CardTitle, EmptyState, formatDateTime, PageHeader, StatusBadge, Table, TBody, TD, TH, THead, TR, type UiLocale } from '@clipper/ui';
import { must, rows } from '@/lib/data';
import { isoToWibInput } from '@/lib/wib';
import { pinCampaign, unpinCampaign, upsertCategory } from '@/features/pinned/actions';
import { BannerEditor } from '@/features/pinned/banner-editor';
import { parseBanners } from '@/features/pinned/banners';
import { ActionButton, ActionDialog, type FieldSpec } from '@/features/shared/action-dialog';
import { rolesFor } from '@/features/shell/nav';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('admin'))('nav.pinned') };
}

// F-A04 / A6.2: urutan pinned (E-06), kategori (E-32), banner beranda (E-25) — semua lewat api.update_config + audit log.
export default async function PinnedPage() {
  await requireAdmin(...rolesFor('pinned'));
  const [t, locale, db] = await Promise.all([getTranslations('admin'), getLocale(), coreServer('admin')]);
  const loc = locale as UiLocale;
  const now = new Date().toISOString();
  const [pinRes, candRes, catRes, bannerRes] = await Promise.all([
    db.from('campaigns').select('id, title, status, pinned_rank, pinned_until').or(`pinned_rank.not.is.null,pinned_until.gt.${now}`)
      .order('pinned_rank', { ascending: true, nullsFirst: false }).limit(100),
    db.from('campaigns').select('id, title').in('status', ['live', 'scheduled', 'paused']).eq('is_template', false)
      .order('created_at', { ascending: false }).limit(100),
    db.from('categories').select('id, name_id, name_en, sort, active').order('sort'),
    db.from('settings').select('value').eq('key', 'public.home.banners').maybeSingle(),
  ]);
  const pinned = rows(pinRes);
  const candidates = rows(candRes);
  const categories = rows(catRes);
  const pinFields = (rank?: number | null, until?: string | null): FieldSpec[] => [
    { kind: 'number', name: 'rank', label: t('pinned.rank'), helper: t('pinned.rankHelp'), min: 1, step: '1', defaultValue: rank ? String(rank) : '' },
    { kind: 'datetime', name: 'until', label: t('pinned.until'), helper: t('form.wib'), defaultValue: isoToWibInput(until) },
  ];
  const catFields = (c?: (typeof categories)[number]): FieldSpec[] => [
    ...(c ? [] : [{ kind: 'text', name: 'id', label: t('pinned.catId'), helper: t('pinned.catIdHelp'), required: true, maxLength: 30 } as FieldSpec]),
    { kind: 'text', name: 'name_id', label: t('pinned.catNameId'), required: true, defaultValue: c?.name_id ?? '', maxLength: 60 },
    { kind: 'text', name: 'name_en', label: t('pinned.catNameEn'), required: true, defaultValue: c?.name_en ?? '', maxLength: 60 },
    { kind: 'number', name: 'sort', label: t('pinned.catSort'), step: '1', defaultValue: String(c?.sort ?? categories.length + 1) },
    { kind: 'checkbox', name: 'active', label: t('pinned.catActive'), defaultChecked: c?.active ?? true },
  ];

  return (
    <>
      <PageHeader title={t('pinned.title')} description={t('pinned.description')} />
      <div className="flex flex-col gap-6">
        <Card padding="none">
          <CardHeader
            className="px-5 pt-5"
            actions={
              <ActionDialog
                trigger={{ label: t('pinned.pin'), icon: 'keep', variant: 'primary' }}
                title={t('pinned.pin')}
                submitLabel={t('pinned.pin')}
                success={t('pinned.saved')}
                action={pinCampaign.bind(null, null)}
                fields={[
                  { kind: 'select', name: 'campaign_id', label: t('pinned.campaign'), required: true, options: candidates.map((c) => ({ value: c.id!, label: c.title ?? c.id! })) },
                  ...pinFields(),
                ]}
              />
            }
          >
            <CardTitle>{t('pinned.pinnedTitle')}</CardTitle>
            <CardDescription>{t('pinned.pinnedBody')}</CardDescription>
          </CardHeader>
          {pinned.length === 0 ? (
            <EmptyState compact icon="keep" tone="neutral" title={t('pinned.none')} className="pb-8" />
          ) : (
            <Table containerClassName="mt-3">
              <THead>
                <TR>
                  <TH>{t('pinned.rank')}</TH>
                  <TH>{t('pinned.campaign')}</TH>
                  <TH>{t('pinned.until')}</TH>
                  <TH align="right">{t('form.actions')}</TH>
                </TR>
              </THead>
              <TBody>
                {pinned.map((c) => (
                  <TR key={c.id}>
                    <TD numeric>{c.pinned_rank ?? <Badge tone="paid">{t('pinned.timeOnly')}</Badge>}</TD>
                    <TD>
                      <span className="font-semibold break-words text-ink">{c.title}</span>{' '}
                      <StatusBadge kind="campaign" status={c.status!} label={t(`status.campaign.${c.status}`)} />
                    </TD>
                    <TD muted>{c.pinned_until ? formatDateTime(c.pinned_until, loc) : '∞'}</TD>
                    <TD align="right">
                      <div className="flex justify-end gap-2">
                        <ActionDialog
                          trigger={{ label: t('form.edit'), icon: 'edit', variant: 'tertiary' }}
                          title={t('pinned.editPin')}
                          description={c.title ?? ''}
                          submitLabel={t('form.save')}
                          success={t('pinned.saved')}
                          action={pinCampaign.bind(null, c.id!)}
                          fields={pinFields(c.pinned_rank, c.pinned_until)}
                        />
                        <ActionButton label={t('pinned.unpin')} icon="close" variant="ghost" success={t('pinned.unpinned')} action={unpinCampaign.bind(null, c.id!)} />
                      </div>
                    </TD>
                  </TR>
                ))}
              </TBody>
            </Table>
          )}
        </Card>

        <Card padding="none">
          <CardHeader
            className="px-5 pt-5"
            actions={
              <ActionDialog
                trigger={{ label: t('pinned.addCategory'), icon: 'add' }}
                title={t('pinned.addCategory')}
                submitLabel={t('form.save')}
                success={t('pinned.catSaved')}
                action={upsertCategory.bind(null, null)}
                fields={catFields()}
              />
            }
          >
            <CardTitle>{t('pinned.categories')}</CardTitle>
          </CardHeader>
          <Table containerClassName="mt-3">
            <THead>
              <TR>
                <TH>{t('pinned.catId')}</TH>
                <TH>{t('pinned.catNameId')}</TH>
                <TH>{t('pinned.catNameEn')}</TH>
                <TH align="right">{t('pinned.catSort')}</TH>
                <TH>{t('pinned.catActive')}</TH>
                <TH align="right">{t('form.actions')}</TH>
              </TR>
            </THead>
            <TBody>
              {categories.map((c) => (
                <TR key={c.id}>
                  <TD className="font-mono text-caption">{c.id}</TD>
                  <TD>{c.name_id}</TD>
                  <TD>{c.name_en}</TD>
                  <TD numeric>{c.sort}</TD>
                  <TD>{c.active ? <Badge tone="success">{t('common.active')}</Badge> : <Badge tone="neutral">{t('common.inactive')}</Badge>}</TD>
                  <TD align="right">
                    <ActionDialog
                      trigger={{ label: t('form.edit'), icon: 'edit', variant: 'tertiary' }}
                      title={t('pinned.editCategory')}
                      description={c.id ?? ''}
                      submitLabel={t('form.save')}
                      success={t('pinned.catSaved')}
                      action={upsertCategory.bind(null, c.id!)}
                      fields={catFields(c)}
                    />
                  </TD>
                </TR>
              ))}
            </TBody>
          </Table>
        </Card>

        <Card padding="md" className="flex flex-col gap-4">
          <CardHeader>
            <CardTitle>{t('pinned.banners')}</CardTitle>
            <CardDescription>{t('pinned.bannersBody')}</CardDescription>
          </CardHeader>
          <BannerEditor initial={parseBanners(must(bannerRes)?.value)} canEdit />
        </Card>
      </div>
    </>
  );
}
