import { getTranslations } from 'next-intl/server';
import { coreServer } from '@clipper/auth/server';
import { formatDateTime, Icon, type UiLocale } from '@clipper/ui';
import { Brief } from '@/features/shared/brief';
import { assetHrefs, fileName, type AssetRow } from '@/features/campaign-review/assets';

/** Panel samping builder admin (A7.2): brief mentah brand + berkas internal (signed URL 10 menit). */
export async function SidePanel({ detail, loc }: { detail: Record<string, unknown>; loc: UiLocale }) {
  const [t, db] = await Promise.all([getTranslations('admin'), coreServer('admin')]);
  const c = (detail.campaign ?? {}) as { brief?: string; managed_brief?: string | null; created_at?: string };
  // managed_brief = brief mentah brand (terpisah dari brief terstruktur); kosong → brief.
  const raw = c.managed_brief?.trim() ? c.managed_brief : c.brief;
  const files = ((detail.assets ?? []) as AssetRow[]).filter((a) => a.audience === 'internal');
  const hrefs = await assetHrefs(db, files);
  return (
    <div className="flex flex-col gap-4">
      {c.created_at ? <p className="text-caption text-muted">{t('campaigns.requested')} {formatDateTime(c.created_at, loc)}</p> : null}
      <section className="flex flex-col gap-2">
        <h3 className="text-label text-ink">{t('campaigns.rawBrief')}</h3>
        <Brief text={raw} />
        <p className="text-caption text-muted">{t('builder.rawBriefNote')}</p>
      </section>
      <section className="flex flex-col gap-2">
        <h3 className="text-label text-ink">{t('builder.internalFiles')}</h3>
        {files.length === 0 ? <p className="text-body-s text-muted">{t('campaigns.noInternalFiles')}</p> : null}
        <ul className="flex flex-col gap-1.5">
          {files.map((f) => (
            <li key={f.id} className="flex items-center gap-2 text-body-s">
              <Icon name={f.kind === 'link' ? 'link' : 'description'} size={18} className="text-muted" />
              <a href={hrefs.get(f.id!)} target="_blank" rel="noopener noreferrer" className="min-w-0 truncate font-semibold text-link hover:underline">
                {fileName(f)}
              </a>
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}
