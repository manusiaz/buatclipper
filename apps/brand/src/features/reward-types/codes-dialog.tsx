'use client';

import { useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Button, Dialog, DialogContent, DialogTrigger, Field, Textarea, toast } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { uploadRewardCodes } from './actions';
import { parseCodes } from './codes';

const MAX = 10_000;

export function CodesDialog({ orgId, rewardTypeId, name }: { orgId: string; rewardTypeId: string; name: string }) {
  const t = useTranslations('brand.rewardTypes');
  const errText = useErrorText();
  const [open, setOpen] = useState(false);
  const [text, setText] = useState('');
  const [csv, setCsv] = useState(false);
  const [pending, start] = useTransition();
  const codes = parseCodes(text, csv);
  const tooMany = codes.length > MAX;

  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        setOpen(o);
        if (o) {
          setText('');
          setCsv(false);
        }
      }}
    >
      <DialogTrigger asChild>
        <Button variant="secondary" size="sm" iconLeft="upload">{t('uploadCodes')}</Button>
      </DialogTrigger>
      <DialogContent
        title={t('codesTitle', { name })}
        description={t('codesBody')}
        footer={
          <>
            <Button variant="secondary" onClick={() => setOpen(false)}>{t('cancel')}</Button>
            <Button
              loading={pending}
              disabled={!codes.length || tooMany}
              onClick={() =>
                start(async () => {
                  const res = await uploadRewardCodes(orgId, rewardTypeId, codes);
                  if (!res.ok) return void toast.error(errText(res.error));
                  toast.success(t('codesAdded', { added: res.added, sent: codes.length }));
                  setOpen(false);
                })
              }
            >
              {t('codesSubmit', { count: codes.length })}
            </Button>
          </>
        }
      >
        <div className="flex flex-col gap-3">
          <Field label={t('codesFile')} optional={t('optional')}>
            <input
              type="file"
              accept=".csv,.txt,text/csv,text/plain"
              className="block w-full text-body-s text-text-2 file:mr-3 file:h-10 file:rounded-control file:border-0 file:bg-subtle file:px-4 file:font-semibold file:text-ink"
              onChange={async (e) => {
                const f = e.target.files?.[0];
                if (!f) return;
                setCsv(/\.csv$/i.test(f.name) || f.type === 'text/csv');
                setText(await f.text());
              }}
            />
          </Field>
          <Field
            label={t('codesText')}
            helper={t('codesHelp', { max: MAX.toLocaleString('id-ID') })}
            error={tooMany ? t('codesTooMany', { max: MAX.toLocaleString('id-ID') }) : undefined}
            labelAside={t('codesCount', { count: codes.length })}
          >
            <Textarea
              value={text}
              onChange={(e) => setText(e.target.value)}
              rows={8}
              textareaClassName="font-mono"
            />
          </Field>
        </div>
      </DialogContent>
    </Dialog>
  );
}
