'use client';

import { useState, useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import {
  Button,
  Card,
  Checkbox,
  Countdown,
  Dialog,
  DialogContent,
  EmbedFrame,
  Field,
  PlatformChip,
  RelativeTime,
  Select,
  Textarea,
  toast,
  type Platform,
} from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { reviewSubmissions } from './actions';
import { REJECT_REASONS, type RejectReason } from './reasons';

export interface QueueItem {
  id: string;
  campaignTitle: string;
  username: string;
  platform: string;
  url: string;
  createdAt: string;
  autoApproveAt: string;
}

export function ReviewQueue({ orgId, items, canReview }: { orgId: string; items: QueueItem[]; canReview: boolean }) {
  const t = useTranslations('brand.review');
  const errText = useErrorText();
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [open, setOpen] = useState<Set<string>>(new Set());
  const [rejectFor, setRejectFor] = useState<string[] | null>(null);
  const [reason, setReason] = useState<RejectReason>('off_brief');
  const [message, setMessage] = useState('');
  const [pending, start] = useTransition();
  const allSelected = items.length > 0 && items.every((i) => selected.has(i.id));
  const toggle = (set: Set<string>, id: string) => {
    const next = new Set(set);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    return next;
  };

  const decide = (ids: string[], decision: 'approve' | 'reject') =>
    start(async () => {
      const res = await reviewSubmissions(orgId, ids, decision, decision === 'reject' ? reason : undefined, decision === 'reject' ? message : undefined);
      if (res.done.length) toast.success(t(decision === 'approve' ? 'approved' : 'rejected', { count: res.done.length }));
      if (res.failed.length) toast.error(t('failed', { count: res.failed.length, error: errText(res.failed[0]!.error) }));
      setSelected((cur) => new Set([...cur].filter((id) => !res.done.includes(id))));
      if (decision === 'reject') {
        setRejectFor(null);
        setMessage('');
      }
    });

  return (
    <div className="flex flex-col gap-4">
      {canReview ? (
        <Card padding="sm" className="sticky top-[calc(var(--safe-top)+72px)] z-10 flex flex-wrap items-center gap-3">
          <Checkbox
            checked={allSelected ? true : selected.size ? 'indeterminate' : false}
            onCheckedChange={(v) => setSelected(v === true ? new Set(items.map((i) => i.id)) : new Set())}
            label={t('selectAll', { count: selected.size })}
          />
          <div className="ml-auto flex flex-wrap gap-2">
            <Button variant="secondary" size="sm" iconLeft="cancel" disabled={!selected.size || pending} onClick={() => setRejectFor([...selected])}>
              {t('rejectSelected')}
            </Button>
            <Button size="sm" iconLeft="check" disabled={!selected.size} loading={pending && !rejectFor} onClick={() => decide([...selected], 'approve')}>
              {t('approveSelected')}
            </Button>
          </div>
        </Card>
      ) : null}

      <ul className="grid grid-cols-1 gap-3 lg:grid-cols-2 [&>*]:min-w-0">
        {items.map((i) => (
          <li key={i.id}>
            <Card padding="md" className="flex h-full flex-col gap-3" data-selected={selected.has(i.id) || undefined}>
              <div className="flex items-start gap-3">
                {canReview ? (
                  <Checkbox
                    checked={selected.has(i.id)}
                    onCheckedChange={() => setSelected((cur) => toggle(cur, i.id))}
                    aria-label={t('select', { user: i.username })}
                  />
                ) : null}
                <div className="flex min-w-0 flex-1 flex-col gap-1">
                  <p className="truncate text-body-s font-bold text-ink">{i.campaignTitle}</p>
                  <p className="flex flex-wrap items-center gap-2 text-caption text-muted">
                    <PlatformChip platform={i.platform as Platform} />
                    <span className="truncate">@{i.username || '—'}</span>
                    <span aria-hidden>·</span>
                    <RelativeTime value={i.createdAt} locale={locale} />
                  </p>
                </div>
              </div>
              <div className="flex flex-wrap items-center gap-2 text-caption text-muted">
                <span>{t('autoIn')}</span>
                <Countdown target={i.autoApproveAt} withIcon warnAtHours={12} dangerAtHours={3} expiredLabel={t('autoSoon')} />
              </div>
              {open.has(i.id) ? (
                <EmbedFrame url={i.url} title={t('preview', { user: i.username })} maxWidth={360} openLabel={t('openOriginal')} className="mx-auto w-full" />
              ) : (
                <Button variant="tertiary" size="sm" iconLeft="play_circle" className="self-start" onClick={() => setOpen((cur) => toggle(cur, i.id))}>
                  {t('showPreview')}
                </Button>
              )}
              <a href={i.url} target="_blank" rel="noopener noreferrer" className="truncate text-caption text-link focus-ring rounded-[4px]">{i.url}</a>
              {canReview ? (
                <div className="mt-auto flex gap-2 pt-1">
                  <Button variant="secondary" size="sm" iconLeft="cancel" className="flex-1" disabled={pending} onClick={() => setRejectFor([i.id])}>
                    {t('reject')}
                  </Button>
                  <Button size="sm" iconLeft="check" className="flex-1" disabled={pending} onClick={() => decide([i.id], 'approve')}>
                    {t('approve')}
                  </Button>
                </div>
              ) : null}
            </Card>
          </li>
        ))}
      </ul>

      <Dialog open={!!rejectFor} onOpenChange={(o) => !o && setRejectFor(null)}>
        <DialogContent
          title={t('rejectTitle', { count: rejectFor?.length ?? 0 })}
          description={t('rejectBody')}
          footer={
            <>
              <Button variant="secondary" onClick={() => setRejectFor(null)}>{t('cancel')}</Button>
              <Button variant="danger" loading={pending} onClick={() => rejectFor && decide(rejectFor, 'reject')}>{t('rejectConfirm')}</Button>
            </>
          }
        >
          <div className="flex flex-col gap-4">
            <Field label={t('reason')} required>
              <Select
                value={reason}
                onValueChange={(v) => setReason(v as RejectReason)}
                options={REJECT_REASONS.map((r) => ({ value: r, label: t(`reasons.${r}`) }))}
              />
            </Field>
            <Field label={t('message')} helper={t('messageHelp')} optional={t('optional')}>
              <Textarea value={message} onChange={(e) => setMessage(e.target.value)} maxLength={1000} showCount rows={3} />
            </Field>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}
