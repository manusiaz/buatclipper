'use client';

import { useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { signOut } from '@clipper/auth/actions';
import { Button } from '@clipper/ui';

export function SignOutButton() {
  const t = useTranslations('clipper.menu');
  const [pending, start] = useTransition();
  return (
    <Button
      variant="danger"
      iconLeft="logout"
      fullWidth
      loading={pending}
      onClick={() =>
        start(async () => {
          await signOut('sso');
        })
      }
    >
      {t('signOut')}
    </Button>
  );
}
