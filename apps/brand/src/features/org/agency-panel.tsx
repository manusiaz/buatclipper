'use client';

import { useState, useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { Badge, Button, Card, CardContent, CardDescription, CardHeader, CardTitle, ConfirmDialog, EmptyState, Field, Input, formatDate, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { linkAgency } from './actions';

export interface AgencyLink {
  agencyId: string;
  clientId: string;
  /** Nama org lawan (kosong kalau RLS tidak membukanya). */
  otherName: string;
  state: 'pending' | 'approved' | 'revoked';
  at: string;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function AgencyPanel({
  orgId,
  isAgency,
  canRequest,
  canRevokeAsAgency,
  isClientOwner,
  asAgency,
  asClient,
}: {
  orgId: string;
  isAgency: boolean;
  canRequest: boolean;
  canRevokeAsAgency: boolean;
  isClientOwner: boolean;
  asAgency: AgencyLink[];
  asClient: AgencyLink[];
}) {
  const t = useTranslations('brand.agency');
  const errText = useErrorText();
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [client, setClient] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [, start] = useTransition();
  const clientValid = UUID_RE.test(client.trim());

  const act = (key: string, agency: string, clientId: string, action: 'request' | 'approve' | 'reject' | 'revoke') =>
    new Promise<void>((resolve) => {
      setBusy(key);
      start(async () => {
        const res = await linkAgency(orgId, agency, clientId, action);
        setBusy(null);
        resolve();
        if (!res.ok) return void toast.error(errText(res.error));
        toast.success(t(`done.${action}`));
        if (action === 'request') setClient('');
      });
    });

  const stateBadge = (s: AgencyLink['state']) => (
    <Badge tone={s === 'approved' ? 'success' : s === 'pending' ? 'warn' : 'neutral'}>{t(`state.${s}`)}</Badge>
  );
  const name = (l: AgencyLink, id: string) => l.otherName || t('unknownOrg', { id: id.slice(0, 8) });

  return (
    <div className="flex flex-col gap-4">
      {isAgency ? (
        <Card>
          <CardHeader>
            <CardTitle>{t('agencyTitle')}</CardTitle>
            <CardDescription>{t('agencyBody')}</CardDescription>
          </CardHeader>
          <CardContent className="flex flex-col gap-4">
            {canRequest ? (
              <form
                className="flex flex-col gap-3 sm:flex-row sm:items-end"
                onSubmit={(e) => {
                  e.preventDefault();
                  if (clientValid) void act('request', orgId, client.trim(), 'request');
                }}
              >
                <Field label={t('clientId')} helper={t('clientIdHelp')} error={client && !clientValid ? t('clientIdInvalid') : undefined} className="flex-1">
                  <Input value={client} onChange={(e) => setClient(e.target.value)} inputClassName="font-mono" placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" />
                </Field>
                <Button type="submit" iconLeft="send" disabled={!clientValid} loading={busy === 'request'}>{t('request')}</Button>
              </form>
            ) : null}
            {asAgency.length ? (
              <ul className="divide-y divide-border">
                {asAgency.map((l) => (
                  <li key={l.clientId} className="flex flex-wrap items-center gap-3 py-3">
                    <span className="min-w-0 flex-1 truncate text-body-s font-semibold text-ink">{name(l, l.clientId)}</span>
                    {stateBadge(l.state)}
                    <span className="text-caption text-muted">{formatDate(l.at, locale)}</span>
                    {canRevokeAsAgency && l.state !== 'revoked' ? (
                      <ConfirmDialog
                        trigger={<Button variant="ghost" size="sm" iconLeft="link_off">{t('revoke')}</Button>}
                        title={t('revokeTitle')}
                        description={t('revokeBody')}
                        confirmLabel={t('revoke')}
                        cancelLabel={t('cancel')}
                        tone="danger"
                        loading={busy === `revoke:${l.clientId}`}
                        onConfirm={() => act(`revoke:${l.clientId}`, orgId, l.clientId, 'revoke')}
                      />
                    ) : null}
                  </li>
                ))}
              </ul>
            ) : (
              <EmptyState compact icon="groups" title={t('noClients')} />
            )}
          </CardContent>
        </Card>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>{t('clientTitle')}</CardTitle>
          <CardDescription>{isClientOwner ? t('clientBody') : t('clientOwnerOnly')}</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          <p className="text-caption text-muted">
            {t('yourOrgId')} <span className="font-mono text-text-2 select-all">{orgId}</span>
          </p>
          {asClient.length ? (
            <ul className="divide-y divide-border">
              {asClient.map((l) => (
                <li key={l.agencyId} className="flex flex-wrap items-center gap-3 py-3">
                  <span className="min-w-0 flex-1 truncate text-body-s font-semibold text-ink">{name(l, l.agencyId)}</span>
                  {stateBadge(l.state)}
                  <span className="text-caption text-muted">{formatDate(l.at, locale)}</span>
                  {isClientOwner && l.state === 'pending' ? (
                    <span className="flex gap-2">
                      <Button variant="secondary" size="sm" loading={busy === `reject:${l.agencyId}`} onClick={() => act(`reject:${l.agencyId}`, l.agencyId, orgId, 'reject')}>
                        {t('reject')}
                      </Button>
                      <Button size="sm" iconLeft="check" loading={busy === `approve:${l.agencyId}`} onClick={() => act(`approve:${l.agencyId}`, l.agencyId, orgId, 'approve')}>
                        {t('approve')}
                      </Button>
                    </span>
                  ) : null}
                  {isClientOwner && l.state === 'approved' ? (
                    <ConfirmDialog
                      trigger={<Button variant="ghost" size="sm" iconLeft="link_off">{t('revoke')}</Button>}
                      title={t('revokeClientTitle')}
                      description={t('revokeClientBody')}
                      confirmLabel={t('revoke')}
                      cancelLabel={t('cancel')}
                      tone="danger"
                      loading={busy === `revoke:${l.agencyId}`}
                      onConfirm={() => act(`revoke:${l.agencyId}`, l.agencyId, orgId, 'revoke')}
                    />
                  ) : null}
                </li>
              ))}
            </ul>
          ) : (
            <EmptyState compact icon="link" title={t('noAgencies')} />
          )}
        </CardContent>
      </Card>
    </div>
  );
}
