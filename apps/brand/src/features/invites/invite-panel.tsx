'use client';

import { useState, useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { Alert, Avatar, Button, Card, CardContent, CardDescription, CardHeader, CardTitle, EmptyState, Field, RelativeTime, Textarea, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { inviteClippers } from './actions';

export function InvitePanel({
  orgId,
  campaignId,
  canInvite,
  invites,
}: {
  orgId: string;
  campaignId: string;
  canInvite: boolean;
  invites: { userId: string; username: string; at: string }[];
}) {
  const t = useTranslations('brand.invites');
  const errText = useErrorText();
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [raw, setRaw] = useState('');
  const [pending, start] = useTransition();

  const submit = () =>
    start(async () => {
      const res = await inviteClippers(orgId, campaignId, raw);
      if (!res.ok) return void toast.error(errText(res.error));
      setRaw('');
      if (res.added === 0) toast.info(t('noneAdded', { count: res.sent }));
      else toast.success(t('added', { added: res.added, sent: res.sent }));
    });

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-[minmax(0,2fr)_minmax(0,3fr)] [&>*]:min-w-0">
      <Card>
        <CardHeader>
          <CardTitle>{t('title')}</CardTitle>
          <CardDescription>{t('description')}</CardDescription>
        </CardHeader>
        <CardContent>
          {canInvite ? (
            <form
              className="flex flex-col gap-3"
              onSubmit={(e) => {
                e.preventDefault();
                submit();
              }}
            >
              <Field label={t('usernames')} helper={t('usernamesHelp')}>
                <Textarea value={raw} onChange={(e) => setRaw(e.target.value)} rows={5} placeholder="@raka.clips, @nara.gg" />
              </Field>
              <Button type="submit" loading={pending} disabled={!raw.trim()} iconLeft="person_add" className="self-start">
                {t('submit')}
              </Button>
            </form>
          ) : (
            <Alert tone="info">{t('readOnly')}</Alert>
          )}
        </CardContent>
      </Card>
      <Card padding="none">
        <CardHeader className="px-5 pt-5">
          <CardTitle>{t('listTitle', { count: invites.length })}</CardTitle>
        </CardHeader>
        {invites.length ? (
          <ul className="max-h-[480px] divide-y divide-border overflow-y-auto">
            {invites.map((i) => (
              <li key={i.userId} className="flex items-center gap-3 px-5 py-3">
                <Avatar name={i.username || '?'} size={32} />
                <span className="min-w-0 flex-1 truncate text-body-s font-semibold text-ink">@{i.username || '—'}</span>
                <RelativeTime value={i.at} locale={locale} className="text-caption text-muted" />
              </li>
            ))}
          </ul>
        ) : (
          <EmptyState compact icon="person_add" title={t('empty')} className="pb-6" />
        )}
      </Card>
    </div>
  );
}
