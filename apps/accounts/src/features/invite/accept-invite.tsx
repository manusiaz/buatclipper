'use client';

import { useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button } from '@clipper/ui';
import { useErrorText } from '@/lib/use-error-text';
import { acceptInvite } from './actions';

const NEED_NEW_LINK = ['invite_expired', 'invite_used', 'not_found:invite'];

export function AcceptInvite({ token }: { token: string }) {
  const t = useTranslations('accounts.invite');
  const errText = useErrorText();
  const [error, setError] = useState<string | null>(null);
  const [leaving, setLeaving] = useState(false);
  const [pending, start] = useTransition();

  const accept = () =>
    start(async () => {
      setError(null);
      const r = await acceptInvite(token);
      if (!r.ok) return setError(r.error);
      setLeaving(true);
      window.location.assign(r.redirect);
    });

  return (
    <div className="flex flex-col gap-4">
      {error && (
        <Alert tone="danger" title={errText(error)}>
          {NEED_NEW_LINK.includes(error) ? t('askNewLink') : null}
        </Alert>
      )}
      <Button size="lg" fullWidth iconLeft="group_add" loading={pending || leaving} onClick={accept}>
        {t('accept')}
      </Button>
    </div>
  );
}
