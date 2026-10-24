'use client';

import { useState } from 'react';
import { useTranslations } from 'next-intl';
import { safeNext } from '@clipper/auth';
import { MfaPanel } from '@clipper/auth/components';
import { Button, EmptyState } from '@clipper/ui';

export interface MfaSectionProps {
  enrolled: boolean;
  aal: string | null;
  next?: string;
}

/**
 * TOTP untuk aksi uang brand (refund/rollover butuh aal2). Panel enroll langsung membuat faktor baru, jadi baru dibuka
 * setelah user menekan tombol — kecuali datang dari brand dengan next (memang sedang diminta MFA).
 */
export function MfaSection({ enrolled, aal, next }: MfaSectionProps) {
  const t = useTranslations('accounts.security');
  const [open, setOpen] = useState(!!next);

  if (enrolled && aal === 'aal2') {
    return (
      <EmptyState icon="verified" tone="success" title={t('activeTitle')} body={t('activeBody')}>
        {next && (
          <Button href={safeNext(next)} iconRight="arrow_forward" className="mt-2">
            {t('continue')}
          </Button>
        )}
      </EmptyState>
    );
  }
  if (open) {
    return (
      <div className="mx-auto w-full max-w-sm">
        <MfaPanel kind="sso" mode={enrolled ? 'challenge' : 'enroll'} next={next} />
      </div>
    );
  }
  return (
    <EmptyState
      icon={enrolled ? 'lock' : 'key'}
      tone={enrolled ? 'primary' : 'warn'}
      title={enrolled ? t('challengeTitle') : t('enrollTitle')}
      body={enrolled ? t('challengeBody') : t('enrollBody')}
    >
      <Button onClick={() => setOpen(true)} iconLeft={enrolled ? 'lock' : 'qr_code_2'} className="mt-2">
        {enrolled ? t('challengeCta') : t('enrollCta')}
      </Button>
    </EmptyState>
  );
}
