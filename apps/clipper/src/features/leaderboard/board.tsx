import { getTranslations } from 'next-intl/server';
import { Avatar, Badge, Icon, cn, formatCompact, type UiLocale } from '@clipper/ui';
import { num } from '@clipper/clipper-lib/pure';
import { publicUrl } from '../lib/server';

export interface BoardRow {
  user_id: string | null;
  username: string | null;
  avatar_path: string | null;
  views: number | null;
  rank: number | null;
}

/** Tabel peringkat; baris sendiri disorot dan ditambahkan di bawah kalau di luar top. */
export async function Board({ rows, mine, uid, locale }: { rows: BoardRow[]; mine: BoardRow | null; uid: string; locale: UiLocale }) {
  const t = await getTranslations('clipper.leaderboard');
  const list = mine && !rows.some((r) => r.user_id === uid) ? [...rows, mine] : rows;
  return (
    <ol className="surface-card flex flex-col divide-y divide-border overflow-hidden rounded-card">
      {list.map((r, i) => {
        const me = r.user_id === uid;
        const rank = num(r.rank);
        const gap = i > 0 && rank - num(list[i - 1]?.rank) > 1;
        return (
          <li
            key={`${r.user_id}-${i}`}
            aria-current={me ? 'true' : undefined}
            className={cn('flex items-center gap-3 px-4 py-3', me && 'bg-primary-soft', gap && 'border-t-2 border-dashed')}
          >
            <span className={cn('w-8 shrink-0 text-center text-body font-extrabold tnum', rank <= 3 ? 'text-primary' : 'text-muted')}>
              {rank <= 3 ? <Icon name="workspace_premium" size={22} filled title={`#${rank}`} /> : `#${rank}`}
            </span>
            <Avatar name={r.username ?? '?'} src={publicUrl('avatars', r.avatar_path)} size={36} />
            <span className="min-w-0 flex-1 truncate text-body-s font-bold text-ink">@{r.username ?? '—'}</span>
            {me ? <Badge tone="primary" size="sm">{t('you')}</Badge> : null}
            <span className="shrink-0 text-body-s font-bold text-ink tnum">{t('views', { n: formatCompact(num(r.views), locale) })}</span>
          </li>
        );
      })}
    </ol>
  );
}
