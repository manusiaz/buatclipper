'use client';

import { useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, Dialog, DialogContent, DialogTrigger, Field, Textarea, toast } from '@clipper/ui';
import { appealSanction } from '@/features/profile/actions';
import { appealSubmission } from './actions';

/** Banding sekali: submisi ditolak (Tugas Saya) atau sanksi akun (Profil, §12). */
export function AppealButton({ submissionId, sanctionId }: { submissionId?: string; sanctionId?: string }) {
  const t = useTranslations(sanctionId ? 'clipper.profile.appeal' : 'clipper.tasks.appeal');
  const [open, setOpen] = useState(false);
  const [text, setText] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const send = () =>
    start(async () => {
      setError(null);
      const r = sanctionId ? await appealSanction(sanctionId, text) : await appealSubmission(submissionId!, text);
      if (!r.ok) return setError(r.message);
      toast.success(t('sent'));
      setOpen(false);
    });

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button size="sm" variant="secondary" iconLeft="gavel">
          {t('cta')}
        </Button>
      </DialogTrigger>
      <DialogContent
        title={t('title')}
        description={t('description')}
        footer={
          <Button fullWidth loading={pending} disabled={!text.trim()} onClick={send}>
            {t('submit')}
          </Button>
        }
      >
        <div className="flex flex-col gap-3">
          {error ? <Alert tone="danger">{error}</Alert> : null}
          <Field label={t('label')} helper={t('helper')} required>
            <Textarea value={text} onChange={(e) => setText(e.target.value)} maxLength={1000} showCount rows={5} />
          </Field>
        </div>
      </DialogContent>
    </Dialog>
  );
}
