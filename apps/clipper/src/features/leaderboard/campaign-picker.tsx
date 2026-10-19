'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { Select } from '@clipper/ui';

export function CampaignPicker({ options, value }: { options: { id: string; title: string }[]; value: string }) {
  const t = useTranslations('clipper.leaderboard');
  const router = useRouter();
  const [pending, start] = useTransition();
  return (
    <div aria-busy={pending}>
      <Select
        aria-label={t('pickCampaign')}
        value={value}
        onValueChange={(v) => start(() => router.replace(`/leaderboard?tab=campaign&campaign=${v}`, { scroll: false }))}
        options={options.map((o) => ({ value: o.id, label: o.title }))}
      />
    </div>
  );
}
