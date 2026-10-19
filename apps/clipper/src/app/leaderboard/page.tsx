import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { requireClipper } from '@clipper/auth/server';
import { Button, EmptyState, Tabs, TabsContent, TabsList, TabsTrigger, formatDate } from '@clipper/ui';
import { Board } from '@/features/leaderboard/board';
import { CampaignPicker } from '@/features/leaderboard/campaign-picker';
import { isUuid } from '@/features/lib/pure';
import { core, uiLocale } from '@/features/lib/server';

export const metadata: Metadata = { title: 'Leaderboard' };

type Props = { searchParams: Promise<{ tab?: string; campaign?: string }> };

const COLS = 'user_id,username,avatar_path,views,rank';

// F-C13 / C4.2: mingguan global + per campaign (api.leaderboard, refresh tiap jam); baris sendiri disorot.
export default async function LeaderboardPage({ searchParams }: Props) {
  const { claims } = await requireClipper();
  const sp = await searchParams;
  const uid = claims.sub;
  const db = await core();
  const [t, locale, latest, mySubs] = await Promise.all([
    getTranslations('clipper.leaderboard'),
    uiLocale(),
    db.from('leaderboard').select('week_start').eq('scope', 'week').order('week_start', { ascending: false }).limit(1).maybeSingle(),
    db.from('submissions').select('campaign_id,created_at').eq('user_id', uid).order('created_at', { ascending: false }).limit(100),
  ]);
  const week = latest.data?.week_start ?? null;
  const campaignIds = [...new Set((mySubs.data ?? []).map((s) => s.campaign_id!).filter(Boolean))];
  const titles = campaignIds.length ? (await db.from('campaigns').select('id,title').in('id', campaignIds)).data ?? [] : [];
  const options = campaignIds
    .map((id) => ({ id, title: titles.find((c) => c.id === id)?.title ?? '' }))
    .filter((o) => o.title);
  const selected = isUuid(sp.campaign) && options.some((o) => o.id === sp.campaign) ? sp.campaign! : options[0]?.id;

  const [weekRows, weekMine, campRows, campMine] = await Promise.all([
    week ? db.from('leaderboard').select(COLS).eq('scope', 'week').eq('week_start', week).order('rank').limit(50) : Promise.resolve({ data: [] }),
    week ? db.from('leaderboard').select(COLS).eq('scope', 'week').eq('week_start', week).eq('user_id', uid).maybeSingle() : Promise.resolve({ data: null }),
    selected ? db.from('leaderboard').select(COLS).eq('scope', 'campaign').eq('campaign_id', selected).order('rank').limit(50) : Promise.resolve({ data: [] }),
    selected
      ? db.from('leaderboard').select(COLS).eq('scope', 'campaign').eq('campaign_id', selected).eq('user_id', uid).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);

  return (
    <div className="flex flex-col gap-4">
      <p className="text-body-s text-muted">{t('description')}</p>
      <Tabs defaultValue={sp.tab === 'campaign' ? 'campaign' : 'week'}>
        <TabsList variant="pill" fullWidth aria-label={t('tabs')}>
          <TabsTrigger value="week" icon="calendar_today">
            {t('week')}
          </TabsTrigger>
          <TabsTrigger value="campaign" icon="campaign">
            {t('perCampaign')}
          </TabsTrigger>
        </TabsList>
        <TabsContent value="week" className="mt-4 flex flex-col gap-3">
          {week ? <p className="text-caption text-muted">{t('weekOf', { date: formatDate(week, locale) })}</p> : null}
          {(weekRows.data ?? []).length ? (
            <Board rows={weekRows.data ?? []} mine={weekMine.data} uid={uid} locale={locale} />
          ) : (
            <EmptyState compact icon="leaderboard" tone="neutral" title={t('emptyTitle')} body={t('emptyBody')} />
          )}
        </TabsContent>
        <TabsContent value="campaign" className="mt-4 flex flex-col gap-3">
          {options.length && selected ? (
            <>
              <CampaignPicker options={options} value={selected} />
              {(campRows.data ?? []).length ? (
                <Board rows={campRows.data ?? []} mine={campMine.data} uid={uid} locale={locale} />
              ) : (
                <EmptyState compact icon="leaderboard" tone="neutral" title={t('emptyTitle')} body={t('emptyBody')} />
              )}
              <Button href={`/campaigns/${selected}`} linkAs={Link} variant="secondary" iconRight="arrow_forward" className="self-start">
                {t('openCampaign')}
              </Button>
            </>
          ) : (
            <EmptyState
              compact
              icon="campaign"
              title={t('noCampaignTitle')}
              body={t('noCampaignBody')}
              action={{ label: t('toCampaigns'), href: '/campaigns', linkAs: Link }}
            />
          )}
        </TabsContent>
      </Tabs>
      <p className="text-caption text-muted">{t('refreshNote')}</p>
    </div>
  );
}
