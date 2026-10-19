'use client';

import { useState, useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import {
  Alert,
  Badge,
  Button,
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
  ConfirmDialog,
  CopyField,
  EmptyState,
  Table,
  TBody,
  TD,
  TH,
  THead,
  TR,
  formatDate,
  toast,
} from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { createReportLink, revokeReportLink } from './actions';

export interface ReportLinkRow {
  id: string;
  createdAt: string;
  expiresAt: string | null;
  revokedAt: string | null;
}

export function ReportPanel({
  orgId,
  campaignId,
  csvHref,
  links,
  canManage,
}: {
  orgId: string;
  campaignId: string;
  csvHref: string;
  links: ReportLinkRow[];
  canManage: boolean;
}) {
  const t = useTranslations('brand.reports');
  const errText = useErrorText();
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [fresh, setFresh] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [revoking, setRevoking] = useState<string | null>(null);
  const now = Date.now();

  const state = (l: ReportLinkRow) =>
    l.revokedAt ? 'revoked' : l.expiresAt && new Date(l.expiresAt).getTime() <= now ? 'expired' : 'active';

  return (
    <div className="flex flex-col gap-4">
      <div className="grid gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>{t('csvTitle')}</CardTitle>
            <CardDescription>{t('csvHint')}</CardDescription>
          </CardHeader>
          <CardContent>
            <Button href={csvHref} variant="secondary" iconLeft="download" download>
              {t('csv')}
            </Button>
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>{t('linkTitle')}</CardTitle>
            <CardDescription>{t('linkHint')}</CardDescription>
          </CardHeader>
          <CardContent className="flex flex-col gap-3">
            {fresh ? (
              <Alert tone="success" title={t('linkCreated')}>
                <div className="mt-2 flex flex-col gap-2">
                  <CopyField value={fresh} label={t('linkLabel')} copyLabel={t('copy')} copiedLabel={t('copied')} mono />
                  <p className="text-caption">{t('onceNote')}</p>
                </div>
              </Alert>
            ) : null}
            {canManage ? (
              <Button
                iconLeft="add_link"
                loading={pending}
                className="self-start"
                onClick={() =>
                  start(async () => {
                    const res = await createReportLink(orgId, campaignId);
                    if (!res.ok) return void toast.error(errText(res.error));
                    setFresh(res.url);
                  })
                }
              >
                {t('create')}
              </Button>
            ) : (
              <p className="text-body-s text-muted">{t('readOnly')}</p>
            )}
          </CardContent>
        </Card>
      </div>

      {links.length ? (
        <Table caption={t('listTitle')} captionVisible>
          <THead>
            <TR>
              <TH>{t('colCreated')}</TH>
              <TH>{t('colExpires')}</TH>
              <TH>{t('colStatus')}</TH>
              <TH align="right"><span className="sr-only">{t('colActions')}</span></TH>
            </TR>
          </THead>
          <TBody>
            {links.map((l) => {
              const s = state(l);
              return (
                <TR key={l.id}>
                  <TD>{formatDate(l.createdAt, locale)}</TD>
                  <TD muted>{l.expiresAt ? formatDate(l.expiresAt, locale) : t('noExpiry')}</TD>
                  <TD>
                    <Badge tone={s === 'active' ? 'success' : 'neutral'} dot={s === 'active'}>{t(`status.${s}`)}</Badge>
                  </TD>
                  <TD align="right">
                    {s === 'active' && canManage ? (
                      <ConfirmDialog
                        trigger={<Button variant="ghost" size="sm" iconLeft="link_off">{t('revoke')}</Button>}
                        title={t('revokeTitle')}
                        description={t('revokeBody')}
                        confirmLabel={t('revoke')}
                        cancelLabel={t('cancel')}
                        tone="danger"
                        loading={revoking === l.id}
                        onConfirm={async () => {
                          setRevoking(l.id);
                          const res = await revokeReportLink(orgId, campaignId, l.id);
                          setRevoking(null);
                          if (!res.ok) toast.error(errText(res.error));
                          else toast.success(t('revoked'));
                        }}
                      />
                    ) : null}
                  </TD>
                </TR>
              );
            })}
          </TBody>
        </Table>
      ) : (
        <Card padding="lg"><EmptyState compact icon="link" title={t('empty')} /></Card>
      )}
    </div>
  );
}
