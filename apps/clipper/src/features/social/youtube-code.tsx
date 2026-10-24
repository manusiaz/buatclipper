'use client';

import { useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, CopyField, Dialog, DialogContent, DialogTrigger, Field, Input, toast } from '@clipper/ui';
import { youtubeCode, youtubeVerify } from './actions';

/** D-11 fallback tanpa OAuth Google: kode di deskripsi channel → akun YouTube terverifikasi (data publik). */
export function YoutubeCode() {
  const t = useTranslations('clipper.social.youtubeCode');
  const ts = useTranslations('clipper.social');
  const [open, setOpen] = useState(false);
  const [channel, setChannel] = useState('');
  const [got, setGot] = useState<{ handle: string; code: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const getCode = () =>
    start(async () => {
      setError(null);
      const r = await youtubeCode(channel);
      if (!r.ok) return setError(r.message);
      setGot(r.data);
    });

  const verify = () =>
    start(async () => {
      setError(null);
      const r = await youtubeVerify(channel);
      if (!r.ok) return setError(r.message);
      toast.success(ts('connected', { platform: 'YouTube' }));
      setOpen(false);
      setGot(null);
      setChannel('');
    });

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button size="sm" variant="ghost" iconLeft="description" className="self-start">
          {t('cta')}
        </Button>
      </DialogTrigger>
      <DialogContent
        title={t('title')}
        description={t('description')}
        footer={
          got ? (
            <Button fullWidth loading={pending} onClick={verify}>
              {t('verify')}
            </Button>
          ) : (
            <Button fullWidth loading={pending} disabled={!channel.trim()} onClick={getCode}>
              {t('getCode')}
            </Button>
          )
        }
      >
        <div className="flex flex-col gap-4">
          {error ? <Alert tone="danger">{error}</Alert> : null}
          <Field label={t('channel')} helper={t('channelHelper')} required>
            <Input
              value={channel}
              maxLength={200}
              inputMode="url"
              autoComplete="off"
              onChange={(e) => {
                setChannel(e.target.value);
                setGot(null);
              }}
            />
          </Field>
          {got ? (
            <>
              <CopyField value={got.code} mono copyLabel={t('copy')} copiedLabel={t('copied')} />
              <ol className="flex list-decimal flex-col gap-1 pl-5 text-body-s text-ink">
                <li>{t('step1')}</li>
                <li>{t('step2', { handle: `@${got.handle}` })}</li>
                <li>{t('step3')}</li>
              </ol>
              <p className="text-caption text-muted">{t('limitNote')}</p>
            </>
          ) : null}
        </div>
      </DialogContent>
    </Dialog>
  );
}
