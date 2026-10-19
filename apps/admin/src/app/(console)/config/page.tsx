import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import { Alert, Card, CardDescription, CardHeader, CardTitle, PageHeader } from '@clipper/ui';
import { rows } from '@/lib/data';
import { updateFeeOverride } from '@/features/config/actions';
import { SettingEditor } from '@/features/config/setting-editor';
import type { Json } from '@/features/config/value';
import { ActionDialog } from '@/features/shared/action-dialog';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('admin'))('nav.config') };
}

// Pengelompokan kunci E-25 (seed db/core/supabase/seed.sql). Kunci yang tidak dikenal masuk "Lainnya"; banner di /pinned.
const GROUPS: [string, (k: string) => boolean][] = [
  ['finance', (k) => k.startsWith('finance.') || k.startsWith('public.finance.')],
  ['market', (k) => k.startsWith('public.market.') || k.startsWith('market.')],
  ['tracking', (k) => k.startsWith('tracking.')],
  ['flags', (k) => k.startsWith('public.flags.') || k.startsWith('public.ai_clip.')],
  ['community', (k) => k.startsWith('public.community.')],
  ['billing', (k) => k.startsWith('public.billing.')],
  ['trust', (k) => k.startsWith('trust.')],
];
const label = (t: (k: string) => string, has: (k: string) => boolean, key: string) => {
  const id = `config.keys.${key.replaceAll('.', '_')}`;
  return has(id) ? t(id) : key;
};

// F-A09 / A6.3: semua config lewat api.update_config (admin_super) + konfirmasi diff; admin lain hanya membaca.
export default async function ConfigPage() {
  const { claims } = await requireAdmin();
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  const canEdit = claims.app_roles.includes('admin_super');
  const [setRes, feeRes] = await Promise.all([
    db.from('settings').select('key, value, updated_at').order('key'),
    db.from('fee_rules').select('mgmt_fee_pct, admin_fee_pct, clipper_fee_pct, instant_withdraw_fee').eq('scope', 'global').maybeSingle(),
  ]);
  const settings = rows(setRes).filter((s) => s.key !== 'public.home.banners');
  const fee = feeRes.data;
  const L = (k: string) => label(t, t.has, k);
  const grouped = GROUPS.map(([g, match]) => [g, settings.filter((s) => match(s.key!) && !s.key!.startsWith('auth.'))] as const);
  const other = settings.filter((s) => !s.key!.startsWith('auth.') && !GROUPS.some(([, m]) => m(s.key!)));
  const locked = settings.filter((s) => s.key!.startsWith('auth.'));
  const feeFields = ['mgmt_fee_pct', 'admin_fee_pct', 'clipper_fee_pct'] as const;

  return (
    <>
      <PageHeader title={t('config.title')} description={t('config.description')} />
      {!canEdit ? (
        <Alert tone="info" className="mb-5">
          {t('config.readOnly')}
        </Alert>
      ) : null}
      <div className="flex flex-col gap-5">
        <Card padding="md">
          <CardHeader
            actions={
              canEdit ? (
                <ActionDialog
                  trigger={{ label: t('config.feeOverride'), icon: 'percent' }}
                  title={t('config.feeOverride')}
                  description={t('config.feeOverrideBody')}
                  submitLabel={t('form.save')}
                  success={t('config.saved')}
                  action={updateFeeOverride}
                  fields={[
                    { kind: 'select', name: 'scope', label: t('config.scope'), required: true, options: [{ value: 'org', label: t('config.scopes.org') }, { value: 'campaign', label: t('config.scopes.campaign') }] },
                    { kind: 'text', name: 'target_id', label: t('config.targetId'), required: true },
                    ...feeFields.map((k) => ({ kind: 'number' as const, name: k, label: t(`config.fee.${k}`), min: 0, max: 100, step: '0.01', suffix: '%' })),
                    { kind: 'number', name: 'instant_withdraw_fee', label: t('config.fee.instant_withdraw_fee'), min: 0, step: '1', prefix: 'Rp' },
                    { kind: 'checkbox', name: 'clear', label: t('config.feeClear') },
                  ]}
                />
              ) : null
            }
          >
            <CardTitle>{t('config.groups.fees')}</CardTitle>
            <CardDescription>{t('config.feesBody')}</CardDescription>
          </CardHeader>
          <div className="mt-2 divide-y divide-border">
            {fee ? (
              <SettingEditor
                settingKey="fee_rules.global"
                label={t('config.feeGlobal')}
                canEdit={canEdit}
                value={{
                  mgmt_fee_pct: Number(fee.mgmt_fee_pct),
                  admin_fee_pct: Number(fee.admin_fee_pct),
                  clipper_fee_pct: Number(fee.clipper_fee_pct),
                  instant_withdraw_fee: Number(fee.instant_withdraw_fee ?? 0),
                }}
              />
            ) : (
              <p className="py-3 text-body-s text-muted">{t('config.feeMissing')}</p>
            )}
          </div>
        </Card>
        {[...grouped, ['other', other] as const].map(([g, list]) =>
          list.length ? (
            <Card key={g} padding="md">
              <CardHeader>
                <CardTitle>{t(`config.groups.${g}`)}</CardTitle>
              </CardHeader>
              <div className="mt-2 divide-y divide-border">
                {list.map((s) => (
                  <SettingEditor key={s.key} settingKey={s.key!} label={L(s.key!)} value={s.value as Json} canEdit={canEdit} />
                ))}
              </div>
            </Card>
          ) : null,
        )}
        {locked.length ? (
          <Card padding="md" variant="tint">
            <CardHeader>
              <CardTitle>{t('config.groups.locked')}</CardTitle>
              <CardDescription>{t('config.lockedBody')}</CardDescription>
            </CardHeader>
            <div className="mt-2 divide-y divide-border">
              {locked.map((s) => (
                <SettingEditor key={s.key} settingKey={s.key!} label={s.key!} value={s.value as Json} canEdit={false} />
              ))}
            </div>
          </Card>
        ) : null}
      </div>
    </>
  );
}
