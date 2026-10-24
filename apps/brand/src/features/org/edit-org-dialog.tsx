'use client';

import { useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, Dialog, DialogContent, DialogTrigger, Field, Input, Textarea, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { updateOrg } from './actions';

type Draft = { name: string; legal_name: string; npwp: string; address: string };

export function EditOrgDialog({ orgId, badan, verified, initial }: { orgId: string; badan: boolean; verified: boolean; initial: Draft }) {
  const t = useTranslations('brand.settings');
  const tn = useTranslations('brand.newOrg');
  const errText = useErrorText();
  const [open, setOpen] = useState(false);
  const [d, setD] = useState(initial);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const set = (k: keyof Draft, v: string) => setD((cur) => ({ ...cur, [k]: v }));
  const npwp = d.npwp.replace(/\D/g, '');
  const issues = {
    name: d.name.trim().length < 2,
    legal_name: badan && !d.legal_name.trim(),
    npwp: badan && !/^\d{15,16}$/.test(npwp),
    address: badan && !d.address.trim(),
  };
  const legalChanged =
    badan && (d.legal_name.trim() !== initial.legal_name || npwp !== initial.npwp || d.address.trim() !== initial.address);

  const submit = () => {
    if (Object.values(issues).some(Boolean)) return setError(errText(`invalid:${Object.entries(issues).find(([, bad]) => bad)![0]}`));
    start(async () => {
      const res = await updateOrg(orgId, d);
      if (!res.ok) return setError(errText(res.error));
      toast.success(verified && legalChanged ? t('savedReverify') : t('saved'));
      setOpen(false);
    });
  };

  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        setOpen(o);
        if (o) {
          setD(initial);
          setError(null);
        }
      }}
    >
      <DialogTrigger asChild>
        <Button variant="secondary" size="sm" iconLeft="edit">{t('edit')}</Button>
      </DialogTrigger>
      <DialogContent
        title={t('editTitle')}
        description={t('editHint')}
        footer={
          <>
            <Button variant="secondary" onClick={() => setOpen(false)}>{t('cancel')}</Button>
            <Button loading={pending} onClick={submit}>{t('save')}</Button>
          </>
        }
      >
        <form
          className="flex flex-col gap-4"
          onSubmit={(e) => {
            e.preventDefault();
            submit();
          }}
        >
          {error ? <Alert tone="danger">{error}</Alert> : null}
          <Field label={t('name')} required>
            <Input value={d.name} onChange={(e) => set('name', e.target.value)} maxLength={100} />
          </Field>
          {badan ? (
            <>
              <Field label={t('legalName')} required>
                <Input value={d.legal_name} onChange={(e) => set('legal_name', e.target.value)} maxLength={200} />
              </Field>
              <Field label={t('npwp')} helper={tn('npwpHelp')} required>
                <Input inputMode="numeric" value={d.npwp} onChange={(e) => set('npwp', e.target.value)} maxLength={20} />
              </Field>
              <Field label={t('address')} required>
                <Textarea rows={3} value={d.address} onChange={(e) => set('address', e.target.value)} maxLength={500} />
              </Field>
              {verified && legalChanged ? <Alert tone="warn">{t('reverifyWarn')}</Alert> : null}
            </>
          ) : null}
        </form>
      </DialogContent>
    </Dialog>
  );
}
