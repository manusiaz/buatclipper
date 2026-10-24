'use client';

import { useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Switch, toast } from '@clipper/ui';
import { setEmailPromotions } from './actions';

export function PromoSwitch({ initial }: { initial: boolean }) {
  const t = useTranslations('clipper.settings');
  const [on, setOn] = useState(initial);
  const [pending, start] = useTransition();
  return (
    <Switch
      checked={on}
      disabled={pending}
      label={t('promo')}
      description={t('promoBody')}
      onCheckedChange={(v) => {
        setOn(v);
        start(async () => {
          const r = await setEmailPromotions(v);
          if (!r.ok) {
            setOn(!v);
            toast.error(r.message);
          } else toast.success(v ? t('promoOn') : t('promoOff'));
        });
      }}
    />
  );
}
