import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { requireClipper } from '@clipper/auth/server';
import {
  Alert,
  Badge,
  Button,
  Card,
  EmptyState,
  Icon,
  PlatformIcon,
  formatCompact,
  platformLabels,
  type BadgeTone,
  type Platform,
} from '@clipper/ui';
import { Flash } from '@/features/lib/flash';
import { enabledPlatforms, isPlatform, num } from '@/features/lib/pure';
import { core, errorText, readSettings, uiLocale } from '@/features/lib/server';
import { IgGuide } from '@/features/social/ig-guide';
import { internalNext } from '@/features/social/oauth';
import { PagePicker } from '@/features/social/page-picker';

export const metadata: Metadata = { title: 'Akun sosmed' };

type Props = { searchParams: Promise<Record<string, string | undefined>> };

const TONE: Record<string, BadgeTone> = { verified: 'success', token_expired: 'warn', revoked: 'danger' };

function parsePages(raw: string | undefined): { id: string; name: string }[] {
  if (!raw) return [];
  try {
    const v = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8'));
    return Array.isArray(v)
      ? v.filter((p) => p && typeof p.id === 'string').map((p) => ({ id: String(p.id).slice(0, 64), name: String(p.name ?? '').slice(0, 80) }))
      : [];
  } catch {
    return [];
  }
}

// F-C02 / C1.5: kartu per platform aktif, maks N akun per platform, Hubungkan / Reconnect lewat OAuth resmi.
export default async function SocialPage({ searchParams }: Props) {
  const { claims } = await requireClipper();
  const sp = await searchParams;
  const next = internalNext(sp.next);
  const db = await core();
  const [t, tc, locale, settings, accounts] = await Promise.all([
    getTranslations('clipper.social'),
    getTranslations('clipper'),
    uiLocale(),
    readSettings(['public.flags.platforms', 'public.market.max_accounts_per_platform']),
    db
      .from('social_accounts')
      .select('id,platform,handle,status,followers,verified_at')
      .eq('user_id', claims.sub)
      .neq('status', 'disconnected')
      .order('created_at'),
  ]);
  const platforms = enabledPlatforms(settings['public.flags.platforms']) as Platform[];
  const max = num(settings['public.market.max_accounts_per_platform']) || 3;
  const list = (accounts.data ?? []).filter((a) => isPlatform(a.platform));
  const start = (p: string) => `/api/oauth/${p}/start${next ? `?next=${encodeURIComponent(next)}` : ''}`;
  const errPlatform = isPlatform(sp.platform) ? (sp.platform as Platform) : null;
  const error = sp.error ? await errorText(sp.error) : null;
  const pages = sp.error === 'page_ambiguous' ? parsePages(sp.pages) : [];
  const connected = isPlatform(sp.connected) ? platformLabels[sp.connected as Platform] : null;

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <h1 className="text-h4 text-ink">{t('title')}</h1>
        <p className="text-body-s text-muted">{t('description')}</p>
      </div>

      {connected ? (
        <>
          <Flash message={t('connected', { platform: connected })} />
          <Alert
            tone="success"
            title={t('connected', { platform: connected })}
            action={next ? { label: t('continue'), href: next, linkAs: Link } : undefined}
          >
            {sp.handle ? t('connectedAs', { handle: sp.handle }) : null}
          </Alert>
        </>
      ) : null}
      {error && sp.error !== 'ig_personal' && sp.error !== 'page_ambiguous' ? (
        <Alert tone="danger" title={errPlatform ? t('errorTitle', { platform: platformLabels[errPlatform] }) : undefined}>
          {error}
        </Alert>
      ) : null}
      {sp.error === 'ig_personal' ? <IgGuide retryHref={start('instagram')} /> : null}
      {sp.error === 'page_ambiguous' ? (
        pages.length ? <PagePicker pages={pages} next={next} /> : <Alert tone="danger">{error}</Alert>
      ) : null}

      {platforms.length === 0 ? (
        <EmptyState icon="link_off" tone="neutral" title={t('noneEnabledTitle')} body={t('noneEnabledBody')} />
      ) : (
        <ul className="flex flex-col gap-3">
          {platforms.map((p) => {
            const mine = list.filter((a) => a.platform === p);
            return (
              <li key={p}>
                <Card className="flex flex-col gap-3">
                  <div className="flex items-center gap-3">
                    <span className="grid size-11 shrink-0 place-items-center rounded-card-sm bg-subtle text-ink">
                      <PlatformIcon platform={p} size={24} />
                    </span>
                    <div className="min-w-0 flex-1">
                      <h2 className="text-h6 text-ink">{platformLabels[p]}</h2>
                      <p className="text-caption text-muted">
                        {mine.length ? t('count', { n: mine.length, max }) : t('notConnected')}
                      </p>
                    </div>
                    {mine.length < max ? (
                      <Button size="sm" variant={mine.length ? 'secondary' : 'primary'} href={start(p)} iconLeft="add_link">
                        {mine.length ? t('addAnother') : t('connect')}
                      </Button>
                    ) : (
                      <Badge tone="neutral">{t('limit')}</Badge>
                    )}
                  </div>
                  {mine.length ? (
                    <ul className="flex flex-col divide-y divide-border rounded-card-sm border border-border">
                      {mine.map((a) => (
                        <li key={a.id} className="flex flex-wrap items-center gap-x-3 gap-y-2 p-3">
                          <div className="min-w-0 flex-1">
                            <p className="truncate text-body-s font-bold text-ink">@{a.handle}</p>
                            <p className="text-caption text-muted tnum">
                              {a.followers != null ? t('followers', { n: formatCompact(a.followers, locale) }) : '—'}
                            </p>
                          </div>
                          <Badge tone={TONE[a.status ?? ''] ?? 'neutral'} size="sm">
                            {t(`status.${a.status}`)}
                          </Badge>
                          {a.status !== 'verified' ? (
                            <Button size="sm" variant="secondary" href={start(p)} iconLeft="refresh">
                              {t('reconnect')}
                            </Button>
                          ) : null}
                        </li>
                      ))}
                    </ul>
                  ) : null}
                </Card>
              </li>
            );
          })}
        </ul>
      )}
      <p className="flex items-start gap-2 text-caption text-muted">
        <Icon name="shield" size={16} className="mt-px shrink-0" />
        {t('privacy')}
      </p>
      {next ? (
        <Button href={next} linkAs={Link} variant="ghost" iconLeft="arrow_back" className="self-start">
          {tc('nav.backToCampaign')}
        </Button>
      ) : null}
    </div>
  );
}
