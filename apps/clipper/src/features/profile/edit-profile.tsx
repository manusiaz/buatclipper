'use client';

import { useRef, useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Avatar, Button, Dialog, DialogContent, DialogTrigger, Field, Input, toast } from '@clipper/ui';
import { avatarUploadUrl, saveProfile } from './actions';

const MAX = 1024 * 1024;
const TYPES = ['image/jpeg', 'image/png', 'image/webp'];

export function EditProfile({ name, avatar }: { name: string; avatar: string | null }) {
  const t = useTranslations('clipper.profile.edit');
  const [open, setOpen] = useState(false);
  const [display, setDisplay] = useState(name);
  const [file, setFile] = useState<File | null>(null);
  const [preview, setPreview] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const input = useRef<HTMLInputElement>(null);

  const pick = (f: File | undefined) => {
    setError(null);
    if (!f) return;
    if (!TYPES.includes(f.type)) return setError(t('photoType'));
    if (f.size > MAX) return setError(t('photoTooBig'));
    setFile(f);
    setPreview(URL.createObjectURL(f));
  };

  const save = () =>
    start(async () => {
      setError(null);
      let path: string | null = null;
      if (file) {
        const up = await avatarUploadUrl(file.type);
        if (!up.ok) return setError(up.message);
        // Sama dengan storage-js uploadToSignedUrl: PUT multipart ke URL bertoken.
        const body = new FormData();
        body.append('cacheControl', '3600');
        body.append('', file);
        const res = await fetch(up.data.signedUrl, { method: 'PUT', body, headers: { 'x-upsert': 'false' } }).catch(() => null);
        if (!res?.ok) return setError(t('uploadFailed'));
        path = up.data.path;
      }
      const r = await saveProfile({ displayName: display, avatarPath: path });
      if (!r.ok) return setError(r.message);
      toast.success(t('saved'));
      setFile(null);
      setOpen(false);
    });

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button size="sm" variant="secondary" iconLeft="edit">
          {t('cta')}
        </Button>
      </DialogTrigger>
      <DialogContent
        title={t('title')}
        description={t('description')}
        footer={
          <Button fullWidth loading={pending} disabled={!display.trim()} onClick={save}>
            {t('save')}
          </Button>
        }
      >
        <div className="flex flex-col gap-4">
          {error ? <Alert tone="danger">{error}</Alert> : null}
          <div className="flex items-center gap-4">
            <Avatar name={display || name || '?'} src={preview ?? avatar} size={64} />
            <div className="flex flex-col gap-1">
              <Button size="sm" variant="secondary" iconLeft="photo_camera" onClick={() => input.current?.click()}>
                {t('photo')}
              </Button>
              <p className="text-caption text-muted">{t('photoHelper')}</p>
            </div>
            <input
              ref={input}
              type="file"
              accept={TYPES.join(',')}
              className="sr-only"
              aria-label={t('photo')}
              onChange={(e) => pick(e.target.files?.[0])}
            />
          </div>
          <Field label={t('name')} required>
            <Input value={display} maxLength={50} onChange={(e) => setDisplay(e.target.value)} autoComplete="nickname" />
          </Field>
        </div>
      </DialogContent>
    </Dialog>
  );
}
