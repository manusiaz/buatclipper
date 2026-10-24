'use client';

import { useState } from 'react';
import { useTranslations } from 'next-intl';
import { Badge, Button, ConfirmDialog, formatDate, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error-text';
import { deleteAccount, setConsent } from './actions';
import type { ConsentKind, ConsentState } from './consents';

const GRANTABLE: ConsentKind[] = ['share_with_brand', 'kyc'];
const LEGAL: ConsentKind[] = ['tos_clipper', 'tos_brand', 'privacy'];

/** Consent aktif + cabut; ToS/privasi/umur yang dicabut diberikan lagi lewat onboarding (reconsentHref). */
export function ConsentList({ items, reconsentHref }: { items: ConsentState[]; reconsentHref: Record<'clipper' | 'brand', string> }) {
  const t = useTranslations('accounts.privacy');
  const errText = useErrorText();
  const [busy, setBusy] = useState<ConsentKind | null>(null);

  const change = async (kind: ConsentKind, granted: boolean) => {
    setBusy(kind);
    const r = await setConsent(kind, granted);
    setBusy(null);
    if (r.ok) toast.success(granted ? t('granted') : t('revoked'));
    else toast.error(errText(r.error));
  };

  return (
    <ul className="divide-y divide-border">
      {items.map((c) => {
        const reconsent = c.kind === 'tos_brand' ? reconsentHref.brand : reconsentHref.clipper;
        return (
          <li key={c.kind} className="flex flex-col gap-3 py-4 first:pt-0 last:pb-0 sm:flex-row sm:items-center">
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-2">
                <p className="text-label text-ink">{t(`kinds.${c.kind}`)}</p>
                <Badge tone={c.active ? 'success' : 'neutral'} size="sm">
                  {c.active ? t('active') : c.revokedAt ? t('revokedBadge') : t('notGiven')}
                </Badge>
              </div>
              <p className="mt-0.5 text-caption text-muted">
                {c.active && c.grantedAt
                  ? LEGAL.includes(c.kind)
                    ? t('since', { date: formatDate(c.grantedAt), version: c.version ?? '—' })
                    : t('sinceDate', { date: formatDate(c.grantedAt) })
                  : c.revokedAt
                    ? t('revokedOn', { date: formatDate(c.revokedAt) })
                    : t(`hints.${c.kind}`)}
              </p>
            </div>
            {c.active ? (
              <ConfirmDialog
                trigger={
                  <Button variant="secondary" size="sm" loading={busy === c.kind}>
                    {t('revoke')}
                  </Button>
                }
                title={t('revokeTitle', { name: t(`kinds.${c.kind}`) })}
                description={t(`revokeEffect.${c.kind}`)}
                confirmLabel={t('revoke')}
                cancelLabel={t('cancel')}
                onConfirm={() => change(c.kind, false)}
              />
            ) : GRANTABLE.includes(c.kind) ? (
              <Button variant="tertiary" size="sm" loading={busy === c.kind} onClick={() => change(c.kind, true)}>
                {t('grant')}
              </Button>
            ) : (
              <Button variant="tertiary" size="sm" href={reconsent}>
                {t('agreeAgain')}
              </Button>
            )}
          </li>
        );
      })}
    </ul>
  );
}

export function DownloadData() {
  const t = useTranslations('accounts.privacy');
  const errText = useErrorText();
  const [pending, setPending] = useState(false);

  const download = async () => {
    setPending(true);
    try {
      const res = await fetch('/privacy/export', { method: 'POST' });
      if (!res.ok) {
        const body = (await res.json().catch(() => null)) as { error?: string } | null;
        return void toast.error(errText(body?.error));
      }
      const name = /filename="([^"]+)"/.exec(res.headers.get('content-disposition') ?? '')?.[1] ?? 'clipper-data.json';
      const url = URL.createObjectURL(await res.blob());
      const a = document.createElement('a');
      a.href = url;
      a.download = name;
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch {
      toast.error(errText('network'));
    } finally {
      setPending(false);
    }
  };

  return (
    <Button variant="secondary" iconLeft="download" loading={pending} loadingText={t('downloading')} onClick={download}>
      {t('download')}
    </Button>
  );
}

export function DeleteAccount({ confirmText }: { confirmText: string }) {
  const t = useTranslations('accounts.privacy');
  const errText = useErrorText();

  const remove = async () => {
    const r = await deleteAccount();
    if (r.ok) return window.location.assign(r.redirect);
    toast.error(errText(r.error), { duration: 10000 });
  };

  return (
    <ConfirmDialog
      trigger={
        <Button variant="danger" iconLeft="delete">
          {t('delete')}
        </Button>
      }
      title={t('deleteTitle')}
      description={t('deleteBody')}
      confirmText={confirmText}
      confirmTextLabel={t('deleteType', { text: confirmText })}
      confirmLabel={t('deleteConfirm')}
      cancelLabel={t('cancel')}
      onConfirm={remove}
    />
  );
}
