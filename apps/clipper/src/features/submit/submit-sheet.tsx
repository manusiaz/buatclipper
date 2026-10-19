'use client';

// C1.8 sheet Submit video: pilih akun per platform campaign → daftar video setelah claim (yang kurang tag wajib sudah
// ditandai) → Submit. "Tempel URL" = cadangan, tetap dicek ke API platform.
import { useEffect, useState, useTransition } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useLocale, useTranslations } from 'next-intl';
import {
  Alert,
  Badge,
  Button,
  cn,
  EmptyState,
  Field,
  Icon,
  Input,
  PlatformIcon,
  Sheet,
  SheetContent,
  Skeleton,
  formatDateTime,
  platformLabels,
  toast,
  type Platform,
} from '@clipper/ui';
import { listVideos, submitVideo, type VideoItem } from './actions';

export interface SubmitAccount {
  id: string;
  platform: Platform;
  handle: string;
  status: string;
}

type Err = { code: string; message: string } | null;

export function SubmitSheet({
  open,
  onOpenChange,
  campaignId,
  claimId,
  accounts,
}: {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  campaignId: string;
  claimId: string;
  accounts: SubmitAccount[];
}) {
  const t = useTranslations('clipper.submit');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const router = useRouter();
  const usable = accounts.filter((a) => a.status === 'verified');
  const [accountId, setAccountId] = useState<string | null>(usable.length === 1 ? usable[0]!.id : null);
  const [videos, setVideos] = useState<VideoItem[] | null>(null);
  const [picked, setPicked] = useState<string | null>(null);
  const [paste, setPaste] = useState(false);
  const [url, setUrl] = useState('');
  const [error, setError] = useState<Err>(null);
  const [loading, startLoad] = useTransition();
  const [sending, startSend] = useTransition();
  const account = accounts.find((a) => a.id === accountId) ?? null;
  const back = `/campaigns/${campaignId}?submit=1`;
  const reconnect = (p: Platform) => `/api/oauth/${p}/start?next=${encodeURIComponent(back)}`;

  const load = (id: string) =>
    startLoad(async () => {
      setError(null);
      setPicked(null);
      const r = await listVideos(id, claimId);
      if (r.ok) setVideos(r.data);
      else {
        setVideos(null);
        setError({ code: r.code, message: r.message });
      }
    });

  useEffect(() => {
    if (open && accountId && videos === null && !error) load(accountId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, accountId]);

  const submit = () =>
    startSend(async () => {
      if (!accountId) return;
      setError(null);
      const r = await submitVideo({ campaignId, claimId, accountId, ...(paste ? { url } : { postId: picked ?? '' }) });
      if (!r.ok) {
        setError({ code: r.code, message: r.message });
        return;
      }
      toast.success(t('success'), { description: t(r.data.status === 'tracking' ? 'successTracking' : 'successReview') });
      onOpenChange(false);
      router.push('/tasks?submitted=1');
    });

  const canSubmit = !!accountId && (paste ? /^https:\/\/\S+$/.test(url.trim()) : !!picked);

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        title={t('title')}
        description={t('description')}
        size="lg"
        footer={
          <Button fullWidth size="lg" iconLeft="send" loading={sending} loadingText={t('sending')} disabled={!canSubmit} onClick={submit}>
            {t('submit')}
          </Button>
        }
      >
        <div className="flex flex-col gap-4 pb-2">
          {accounts.length === 0 ? (
            <EmptyState
              compact
              icon="link"
              title={t('noAccountTitle')}
              body={t('noAccountBody')}
              action={{ label: t('connect'), href: `/social?next=${encodeURIComponent(back)}`, linkAs: Link }}
            />
          ) : (
            <fieldset className="flex flex-col gap-2">
              <legend className="mb-1 text-label text-ink">{t('account')}</legend>
              {accounts.map((a) => {
                const active = a.id === accountId;
                const off = a.status !== 'verified';
                return (
                  <div key={a.id} className="flex items-center gap-2">
                    <button
                      type="button"
                      disabled={off}
                      aria-pressed={active}
                      onClick={() => {
                        setAccountId(a.id);
                        setVideos(null);
                        setError(null);
                        load(a.id);
                      }}
                      className={cn(
                        'flex min-h-12 flex-1 items-center gap-3 rounded-control border px-3 text-left text-body-s focus-ring',
                        active ? 'border-primary bg-primary-soft text-primary-soft-fg' : 'border-border bg-surface hover:border-border-hover',
                        off && 'opacity-60',
                      )}
                    >
                      <PlatformIcon platform={a.platform} size={20} />
                      <span className="min-w-0 flex-1 truncate font-semibold">@{a.handle}</span>
                      {off ? <Badge tone="warn" size="sm">{t('tokenExpired')}</Badge> : active ? <Icon name="check_circle" filled size={18} /> : null}
                    </button>
                    {off ? (
                      <Button size="sm" variant="secondary" href={reconnect(a.platform)} iconLeft="refresh">
                        {t('reconnect')}
                      </Button>
                    ) : null}
                  </div>
                );
              })}
            </fieldset>
          )}

          {error ? (
            <Alert
              tone="danger"
              action={
                (error.code === 'token_expired' || error.code === 'account_inactive') && account
                  ? { label: t('reconnect'), href: reconnect(account.platform) }
                  : undefined
              }
            >
              {error.message}
            </Alert>
          ) : null}

          {account && !paste ? (
            <section className="flex flex-col gap-2" aria-busy={loading}>
              <div className="flex items-center justify-between gap-2">
                <h3 className="text-label text-ink">{t('videos', { platform: platformLabels[account.platform] })}</h3>
                <Button size="sm" variant="ghost" iconLeft="refresh" onClick={() => load(account.id)} disabled={loading}>
                  {t('refresh')}
                </Button>
              </div>
              {loading ? (
                <div className="flex flex-col gap-2">
                  {[0, 1, 2].map((i) => (
                    <Skeleton key={i} className="h-20 w-full" />
                  ))}
                </div>
              ) : videos && videos.length === 0 ? (
                <p className="rounded-card-sm bg-subtle p-4 text-center text-body-s text-muted">{t('noVideos')}</p>
              ) : videos ? (
                <ul className="flex flex-col gap-2" role="radiogroup" aria-label={t('videosLabel')}>
                  {videos.map((v) => {
                    const blocked = v.missingTags.length > 0;
                    const active = picked === v.postId;
                    return (
                      <li key={v.postId}>
                        <button
                          type="button"
                          role="radio"
                          aria-checked={active}
                          aria-disabled={blocked}
                          onClick={() => !blocked && setPicked(v.postId)}
                          className={cn(
                            'flex w-full gap-3 rounded-card-sm border p-2 text-left focus-ring',
                            active ? 'border-primary bg-primary-soft' : 'border-border bg-surface hover:border-border-hover',
                            blocked && 'cursor-not-allowed border-danger-border/70 bg-danger-bg/40',
                          )}
                        >
                          <span className="relative aspect-[9/16] w-14 shrink-0 overflow-hidden rounded-chip bg-navy">
                            {v.thumbnail ? <img src={v.thumbnail} alt="" loading="lazy" className="size-full object-cover" /> : null}
                          </span>
                          <span className="flex min-w-0 flex-1 flex-col gap-1">
                            <span className="line-clamp-2 text-body-s text-ink">{v.caption || t('noCaption')}</span>
                            <span className="text-caption text-muted">
                              {v.postedAt ? formatDateTime(v.postedAt, locale) : ''}
                              {v.durationSec ? ` · ${t('seconds', { n: v.durationSec })}` : ''}
                            </span>
                            {blocked ? (
                              <span className="flex flex-wrap items-center gap-1 text-caption font-semibold text-danger-fg">
                                <Icon name="warning" size={14} filled />
                                {t('missing', { tags: v.missingTags.join(', ') })}
                              </span>
                            ) : null}
                          </span>
                          {active ? <Icon name="check_circle" filled size={20} className="shrink-0 text-primary" /> : null}
                        </button>
                      </li>
                    );
                  })}
                </ul>
              ) : null}
              {videos?.some((v) => v.missingTags.length) ? <p className="text-caption text-muted">{t('missingHint')}</p> : null}
            </section>
          ) : null}

          {account ? (
            paste ? (
              <div className="flex flex-col gap-2">
                <Field label={t('url')} helper={t('urlHelper')}>
                  <Input
                    type="url"
                    inputMode="url"
                    placeholder="https://"
                    value={url}
                    onChange={(e) => setUrl(e.target.value)}
                    autoFocus
                  />
                </Field>
                <Button variant="link" size="sm" className="self-start" onClick={() => setPaste(false)}>
                  {t('backToList')}
                </Button>
              </div>
            ) : (
              <Button variant="link" size="sm" iconLeft="add_link" className="self-start" onClick={() => setPaste(true)}>
                {t('pasteUrl')}
              </Button>
            )
          ) : null}
        </div>
      </SheetContent>
    </Sheet>
  );
}
