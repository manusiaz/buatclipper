// Onboarding clipper (C1.3: profil, username, 18+, ToS) diselesaikan di accounts.{domain}; app memeriksa claim
// consent_ok.clipper setelah token disegarkan.
import { useState } from 'react';
import { useTranslations } from 'use-intl';
import { useAuth } from '@/auth';
import { decodeClaims } from '@/claims';
import { identity } from '@/supabase';
import { Alert, Button, Card, Txt } from '@/ui/core';
import { Screen } from '@/ui/screen';
import { openWeb } from '@/web';

export default function Onboarding() {
  const t = useTranslations('clipper.mobile');
  const { refresh, signOut } = useAuth();
  const [pending, setPending] = useState(false);
  const [notYet, setNotYet] = useState(false);
  const check = async () => {
    setPending(true);
    await refresh();
    const { data } = await identity.auth.getSession();
    setNotYet(!decodeClaims(data.session?.access_token)?.consent_ok?.clipper);
    setPending(false);
  };
  return (
    <Screen title={t('onboardingTitle')}>
      <Card>
        <Txt variant="body" tone="text2">{t('onboardingBody')}</Txt>
        <Button full icon="open_in_new" onPress={() => openWeb('accounts', '/onboarding')}>{t('onboardingOpen')}</Button>
        <Button full variant="secondary" loading={pending} onPress={check}>{t('onboardingDone')}</Button>
      </Card>
      {notYet ? <Alert tone="warn">{t('onboardingPending')}</Alert> : null}
      <Button variant="link" onPress={signOut}>{t('signOut')}</Button>
    </Screen>
  );
}
