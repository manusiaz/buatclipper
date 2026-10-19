'use client';

import { useState, useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import {
  Badge, Button, Card, Checkbox, EmbedFrame, Field, formatNumber, PlatformChip, RelativeTime, Select, StatusBadge, Textarea, toast,
  type Platform, type UiLocale,
} from '@clipper/ui';
import { useErrorText } from '@/features/shared/use-error-text';
import { decideSubmissions } from './actions';

export const SUBMISSION_REASONS = ['missing_tags', 'off_brief', 'low_quality', 'reused_content', 'wrong_account', 'sponsored_label', 'inappropriate', 'fraud_suspected', 'other'] as const;

export interface QueueItem {
  id: string;
  url: string;
  platform: Platform;
  status: 'in_review' | 'appealed';
  created_at: string;
  campaign: string;
  username: string;
  views: number;
  history: { decision: string; reason: string | null; message: string | null; at: string }[];
}

export function ReviewQueue({ items }: { items: QueueItem[] }) {
  const t = useTranslations('admin.review');
  const ta = useTranslations('admin');
  const loc = useLocale() as UiLocale;
  const errorText = useErrorText();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [open, setOpen] = useState<Set<string>>(new Set());
  const [reason, setReason] = useState<string>('');
  const [message, setMessage] = useState('');
  const [pending, start] = useTransition();
  const toggle = (set: Set<string>, id: string) => {
    const n = new Set(set);
    if (n.has(id)) n.delete(id);
    else n.add(id);
    return n;
  };
  const all = items.length > 0 && selected.size === items.length;

  const decide = (decision: 'approve' | 'reject') => {
    if (decision === 'reject' && !reason) return toast.error(t('reasonRequired'));
    const ids = [...selected];
    start(async () => {
      const msg = message.trim() || (decision === 'reject' ? t(`reasons.${reason}`) : '');
      const r = await decideSubmissions(ids, decision, { reason: decision === 'reject' ? reason : undefined, message: msg });
      if (!r.ok || !r.data) return void toast.error(errorText(r.ok ? 'generic' : r.error));
      const { done, failed } = r.data;
      if (done) toast.success(t('decided', { count: done }));
      if (failed.length) toast.error(t('failedSome', { count: failed.length, error: errorText(failed[0]!.error) }));
      setSelected(new Set(failed.map((f) => f.id)));
      setMessage('');
    });
  };

  return (
    <div className="flex flex-col gap-4">
      <Card variant="raised" padding="sm" className="z-10 flex lg:sticky lg:top-[calc(var(--safe-top)+72px)] flex-col gap-3 lg:flex-row lg:items-end">
        <div className="flex items-center gap-3 lg:h-12">
          <Checkbox
            checked={all ? true : selected.size ? 'indeterminate' : false}
            onCheckedChange={() => setSelected(all ? new Set() : new Set(items.map((i) => i.id)))}
            label={t('selected', { count: selected.size })}
          />
        </div>
        <Field label={t('reason')} className="lg:w-60">
          <Select value={reason || undefined} onValueChange={setReason} placeholder={t('reasonPick')} inputSize="sm" options={SUBMISSION_REASONS.map((r) => ({ value: r, label: t(`reasons.${r}`) }))} />
        </Field>
        <Field label={t('message')} optional className="flex-1">
          <Textarea rows={1} value={message} maxLength={500} onChange={(e) => setMessage(e.target.value)} placeholder={t('messageHint')} />
        </Field>
        <div className="flex gap-2">
          <Button variant="danger" iconLeft="block" disabled={!selected.size} loading={pending} onClick={() => decide('reject')}>
            {t('reject')}
          </Button>
          <Button iconLeft="check_circle" disabled={!selected.size} loading={pending} onClick={() => decide('approve')}>
            {t('approve')}
          </Button>
        </div>
      </Card>
      <p className="text-caption text-muted">{t('appealHint')}</p>

      <ul className="flex flex-col gap-3">
        {items.map((s) => (
          <Card as="li" key={s.id} padding="sm" className="flex flex-col gap-3">
            <div className="flex items-start gap-3">
              <Checkbox checked={selected.has(s.id)} onCheckedChange={() => setSelected((x) => toggle(x, s.id))} aria-label={t('selectOne', { name: s.username })} className="mt-1" />
              <div className="flex min-w-0 flex-1 flex-col gap-1">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-semibold break-words text-ink">{s.campaign}</span>
                  <StatusBadge kind="submission" status={s.status} label={ta(`status.submission.${s.status}`)} />
                  <PlatformChip platform={s.platform} />
                </div>
                <p className="flex flex-wrap gap-x-3 text-caption text-muted">
                  <span>@{s.username}</span>
                  <RelativeTime value={s.created_at} locale={loc} />
                  <span className="tnum">{t('views', { n: formatNumber(s.views, loc) })}</span>
                  <a href={s.url} target="_blank" rel="noopener noreferrer" className="max-w-full truncate text-link hover:underline">
                    {s.url}
                  </a>
                </p>
              </div>
              <Button size="sm" variant="tertiary" iconLeft={open.has(s.id) ? 'visibility_off' : 'play_circle'} onClick={() => setOpen((x) => toggle(x, s.id))}>
                {open.has(s.id) ? t('hidePreview') : t('preview')}
              </Button>
            </div>
            {open.has(s.id) ? <EmbedFrame url={s.url} title={t('embedTitle', { name: s.username })} openLabel={t('openPost')} className="mx-auto" /> : null}
            {s.history.length ? (
              <ol className="flex flex-col gap-1 border-l-2 border-border pl-3 text-body-s">
                {s.history.map((h, i) => (
                  <li key={i} className="flex flex-wrap items-center gap-x-2">
                    <Badge tone={h.decision === 'appeal' ? 'primary' : h.decision === 'reject' || h.decision === 'uphold' ? 'danger' : 'success'} size="sm">
                      {t(`decisions.${h.decision}`)}
                    </Badge>
                    {h.reason ? <span className="text-text-2">{t.has(`reasons.${h.reason}`) ? t(`reasons.${h.reason}`) : h.reason}</span> : null}
                    {h.message ? <span className="text-muted">“{h.message}”</span> : null}
                    <RelativeTime value={h.at} locale={loc} className="text-caption text-faint" />
                  </li>
                ))}
              </ol>
            ) : null}
          </Card>
        ))}
      </ul>
    </div>
  );
}
