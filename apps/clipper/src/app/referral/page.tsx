import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { hosts } from '@clipper/auth';
import { requireClipper } from '@clipper/auth/server';
import { Badge, Card, CardHeader, CardTitle, CopyField, EmptyState, ErrorState, Icon, StatCard, formatDate, type BadgeTone } from '@clipper/ui';
import { num } from '@/features/lib/pure';
import { core, errorText, rewardTypes, uiLocale } from '@/features/lib/server';
import { formatAmount } from '@/features/lib/units';
import { ShareButton } from '@/features/referral/share-button';

export const metadata: Metadata = { title: 'Ajak teman' };

// F-C16 / C5.1, C5.3: kode 8 karakter, link {domain}/?ref=<kode>, daftar teman + status bonus, total bonus (ledger).
export default async function ReferralPage() {
  const { claims } = await requireClipper();
  const db = await core();
  const [t, locale, code, friends, bonus] = await Promise.all([
    getTranslations('clipper.referral'),
    uiLocale(),
    db.rpc('my_referral_code'),
    db.from('referrals').select('referred_username,qualified_at,bonus_until,created_at').order('created_at', { ascending: false }).limit(100),
    db.from('wallet_entries').select('reward_type_id,amount').eq('user_id', claims.sub).eq('ref_type', 'referral_bonus').gt('amount', 0),
  ]);
  if (code.error || !code.data) {
    return <ErrorState title={t('errorTitle')} body={await errorText(code.error?.message)} />;
  }
  const link = `${hosts.web}/?ref=${encodeURIComponent(code.data)}`;
  const totals = new Map<string, number>();
  for (const b of bonus.data ?? []) totals.set(b.reward_type_id ?? '', (totals.get(b.reward_type_id ?? '') ?? 0) + num(b.amount));
  const units = await rewardTypes(totals.keys());
  const now = Date.now();
  const status = (f: { qualified_at: string | null; bonus_until: string | null }): { tone: BadgeTone; label: string } => {
    if (!f.qualified_at) return { tone: 'neutral', label: t('statusJoined') };
    if (f.bonus_until && new Date(f.bonus_until).getTime() > now)
      return { tone: 'success', label: t('statusActive', { date: formatDate(f.bonus_until, locale) }) };
    return { tone: 'paid', label: t('statusDone') };
  };
  const list = friends.data ?? [];

  return (
    <div className="flex flex-col gap-4">
      <Card variant="blue" className="flex flex-col gap-3">
        <Icon name="group_add" size={32} filled />
        <h2 className="text-h4">{t('headline')}</h2>
        <p className="text-body-s opacity-90">{t('body')}</p>
      </Card>
      <Card className="flex flex-col gap-3">
        <CopyField value={code.data} label={t('code')} mono copyLabel={t('copy')} copiedLabel={t('copied')} />
        <CopyField value={link} label={t('link')} copyLabel={t('copy')} copiedLabel={t('copied')} />
        <ShareButton url={link} text={t('shareText')} />
      </Card>
      <div className="grid grid-cols-2 gap-3">
        <StatCard label={t('friends')} value={String(list.length)} icon="groups" hint={t('qualified', { n: list.filter((f) => f.qualified_at).length })} />
        <StatCard
          label={t('totalBonus')}
          value={totals.size ? [...totals].map(([id, v]) => formatAmount(v, units.get(id), locale)).join(' + ') : formatAmount(0, null, locale)}
          icon="payments"
          hint={t('bonusHint')}
          footer={
            <Link href="/wallet" className="text-body-s font-semibold text-link hover:underline focus-ring">
              {t('toWallet')}
            </Link>
          }
        />
      </div>
      <Card>
        <CardHeader>
          <CardTitle>{t('howTitle')}</CardTitle>
        </CardHeader>
        <ol className="ml-5 flex list-decimal flex-col gap-1.5 text-body-s text-text-2">
          <li>{t('how1')}</li>
          <li>{t('how2')}</li>
          <li>{t('how3')}</li>
        </ol>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle>{t('listTitle')}</CardTitle>
        </CardHeader>
        {list.length ? (
          <ul className="flex flex-col divide-y divide-border">
            {list.map((f, i) => {
              const s = status(f);
              return (
                <li key={`${f.referred_username}-${i}`} className="flex items-center gap-3 py-2.5 first:pt-0 last:pb-0">
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-body-s font-bold text-ink">@{f.referred_username}</p>
                    <p className="text-caption text-muted">{f.created_at ? t('joinedAt', { date: formatDate(f.created_at, locale) }) : ''}</p>
                  </div>
                  <Badge tone={s.tone} size="sm">
                    {s.label}
                  </Badge>
                </li>
              );
            })}
          </ul>
        ) : (
          <EmptyState compact icon="group_add" tone="neutral" title={t('emptyTitle')} body={t('emptyBody')} />
        )}
      </Card>
    </div>
  );
}
