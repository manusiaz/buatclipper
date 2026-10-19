import { getTranslations } from 'next-intl/server';
import { coreServer } from '@clipper/auth/server';
import { Avatar, Badge, Card, EmptyState, Icon, RelativeTime, type UiLocale } from '@clipper/ui';
import { rows, uniq } from '@/lib/data';
import { Brief } from '@/features/shared/brief';
import { assetHrefs, fileName } from './assets';
import { TakeButton } from './review-detail';

/** A7.1 antrean paket managed: draft managed terlama di atas + org, PIC, brief mentah, berkas internal (signed URL). */
export async function ManagedQueue({ loc }: { loc: UiLocale }) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  const drafts = rows(
    await db.from('campaigns').select('id, org_id, title, brief, created_at').eq('service_mode', 'managed').eq('status', 'draft')
      .order('created_at').limit(100),
  );
  if (drafts.length === 0) return <EmptyState icon="check_circle" tone="success" title={t('campaigns.managedEmpty')} body={t('campaigns.managedEmptyBody')} />;

  const ids = uniq(drafts.map((d) => d.id));
  const orgIds = uniq(drafts.map((d) => d.org_id));
  const [orgs, members, assets] = await Promise.all([
    db.from('organizations').select('id, name').in('id', orgIds),
    db.from('org_members').select('org_id, user_id').in('org_id', orgIds).eq('role', 'brand_owner'),
    db.from('campaign_assets').select('id, campaign_id, kind, storage_path, url, size_bytes, audience').in('campaign_id', ids).eq('audience', 'internal'),
  ]);
  const owners = rows(members);
  const profiles = rows(await db.from('profiles').select('id, username, display_name').in('id', uniq(owners.map((m) => m.user_id))));
  const files = rows(assets);
  const hrefs = await assetHrefs(db, files);
  const orgName = new Map(rows(orgs).map((o) => [o.id, o.name]));
  const profile = new Map(profiles.map((p) => [p.id, p]));

  return (
    <ul className="flex flex-col gap-4">
      {drafts.map((d) => {
        const pics = owners.filter((m) => m.org_id === d.org_id).map((m) => profile.get(m.user_id!)).filter(Boolean);
        const own = files.filter((f) => f.campaign_id === d.id);
        return (
          <Card as="li" key={d.id} padding="md" className="flex flex-col gap-4">
            <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div className="flex min-w-0 flex-col gap-1">
                <p className="text-overline text-muted">{orgName.get(d.org_id!) ?? '—'}</p>
                <h3 className="text-h6 break-words text-ink">{d.title}</h3>
                <p className="text-caption text-muted">
                  {t('campaigns.requested')} <RelativeTime value={d.created_at!} locale={loc} />
                </p>
              </div>
              <TakeButton id={d.id!} label={t('campaigns.take')} />
            </div>
            <div className="flex flex-wrap items-center gap-3">
              <span className="text-caption font-semibold text-muted">{t('campaigns.pic')}</span>
              {pics.length === 0 ? <span className="text-body-s text-muted">—</span> : null}
              {pics.map((p) => (
                <span key={p!.id} className="inline-flex items-center gap-2 text-body-s text-ink">
                  <Avatar name={p!.display_name ?? p!.username ?? '?'} size={24} />
                  {p!.display_name} <span className="text-muted">@{p!.username}</span>
                </span>
              ))}
            </div>
            <details className="group rounded-card-sm bg-subtle p-3">
              <summary className="cursor-pointer text-label text-ink focus-ring">{t('campaigns.rawBrief')}</summary>
              <Brief text={d.brief} className="mt-2" />
            </details>
            <div className="flex flex-wrap gap-2">
              {own.length === 0 ? <span className="text-body-s text-muted">{t('campaigns.noInternalFiles')}</span> : null}
              {own.map((f) => (
                <a key={f.id} href={hrefs.get(f.id!)} target="_blank" rel="noopener noreferrer" className="focus-ring">
                  <Badge tone="outline" icon={f.kind === 'link' ? 'link' : 'description'} className="max-w-64 truncate">
                    {fileName(f)}
                  </Badge>
                </a>
              ))}
            </div>
          </Card>
        );
      })}
    </ul>
  );
}

export { Icon };
