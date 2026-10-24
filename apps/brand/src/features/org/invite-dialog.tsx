'use client';

import { useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, CopyField, Dialog, DialogContent, DialogTrigger, RadioGroup } from '@clipper/ui';
import type { OrgRole } from '@/lib/org';
import { useErrorText } from '@/lib/use-error';
import { createInvite } from './actions';

const ROLES: OrgRole[] = ['brand_manager', 'brand_finance', 'brand_viewer', 'brand_owner'];

/** B2.1 link undangan (berlaku 7 hari), tampil sekali; dibagikan sendiri lewat WhatsApp/email. */
export function InviteDialog({ orgId }: { orgId: string }) {
  const t = useTranslations('brand');
  const errText = useErrorText();
  const [open, setOpen] = useState(false);
  const [role, setRole] = useState<OrgRole>('brand_manager');
  const [url, setUrl] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        setOpen(o);
        if (o) {
          setUrl(null);
          setError(null);
        }
      }}
    >
      <DialogTrigger asChild>
        <Button iconLeft="person_add">{t('team.invite')}</Button>
      </DialogTrigger>
      <DialogContent
        title={t('team.inviteTitle')}
        description={url ? t('team.inviteCreated') : t('team.inviteBody')}
        footer={
          url ? (
            <Button onClick={() => setOpen(false)}>{t('team.done')}</Button>
          ) : (
            <>
              <Button variant="secondary" onClick={() => setOpen(false)}>{t('team.cancel')}</Button>
              <Button
                loading={pending}
                iconLeft="link"
                onClick={() =>
                  start(async () => {
                    const res = await createInvite(orgId, role);
                    if (!res.ok) setError(errText(res.error));
                    else setUrl(res.url);
                  })
                }
              >
                {t('team.createLink')}
              </Button>
            </>
          )
        }
      >
        {url ? (
          <div className="flex flex-col gap-3">
            <CopyField value={url} label={t('team.linkLabel', { role: t(`roles.${role}`) })} mono copyLabel={t('team.copy')} copiedLabel={t('team.copied')} />
            <Alert tone="warn">{t('team.onceNote')}</Alert>
          </div>
        ) : (
          <div className="flex flex-col gap-3">
            {error ? <Alert tone="danger">{error}</Alert> : null}
            <RadioGroup
              name="invite_role"
              legend={t('team.role')}
              legendVisible
              variant="card"
              value={role}
              onValueChange={(v) => setRole(v as OrgRole)}
              options={ROLES.map((r) => ({ value: r, label: t(`roles.${r}`), description: t(`roleHelp.${r}`) }))}
            />
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}
