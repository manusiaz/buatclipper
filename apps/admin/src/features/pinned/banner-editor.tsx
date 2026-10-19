'use client';

import { useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, Card, Field, IconButton, Input, toast } from '@clipper/ui';
import { useErrorText } from '@/features/shared/use-error-text';
import { saveBanners } from './actions';
import { validBanners, type Banner } from './banners';

export function BannerEditor({ initial, canEdit }: { initial: Banner[]; canEdit: boolean }) {
  const t = useTranslations('admin.pinned');
  const errorText = useErrorText();
  const [list, setList] = useState<Banner[]>(initial);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const set = (i: number, patch: Partial<Banner>) => setList((l) => l.map((b, j) => (j === i ? { ...b, ...patch } : b)));
  const move = (i: number, d: -1 | 1) =>
    setList((l) => {
      const n = [...l];
      [n[i], n[i + d]] = [n[i + d]!, n[i]!];
      return n;
    });

  const save = () => {
    if (!validBanners(list)) return setError(t('bannerInvalid'));
    setError(null);
    start(async () => {
      const r = await saveBanners(list);
      if (r.ok) toast.success(t('bannersSaved'));
      else setError(errorText(r.error));
    });
  };

  return (
    <div className="flex flex-col gap-3">
      {error ? <Alert tone="danger">{error}</Alert> : null}
      {list.length === 0 ? <p className="text-body-s text-muted">{t('noBanners')}</p> : null}
      {list.map((b, i) => (
        <Card key={i} variant="outline" padding="sm" className="flex flex-col gap-3 md:flex-row md:items-end">
          <div className="aspect-[16/7] w-full shrink-0 overflow-hidden rounded-card-sm bg-subtle md:w-40">
            {b.img.startsWith('https://') ? <img src={b.img} alt="" className="size-full object-cover" /> : null}
          </div>
          <div className="grid flex-1 gap-3 sm:grid-cols-3">
            <Field label={t('bannerImg')} helper={t('bannerImgHelp')}>
              <Input inputSize="sm" value={b.img} disabled={!canEdit} onChange={(e) => set(i, { img: e.target.value })} />
            </Field>
            <Field label={t('bannerHref')} helper={t('bannerHrefHelp')}>
              <Input inputSize="sm" value={b.href} disabled={!canEdit} onChange={(e) => set(i, { href: e.target.value })} />
            </Field>
            <Field label={t('bannerAlt')}>
              <Input inputSize="sm" value={b.alt} maxLength={120} disabled={!canEdit} onChange={(e) => set(i, { alt: e.target.value })} />
            </Field>
          </div>
          {canEdit ? (
            <div className="flex gap-1">
              <IconButton icon="arrow_upward" label={t('moveUp')} size="sm" variant="ghost" disabled={i === 0} onClick={() => move(i, -1)} />
              <IconButton icon="arrow_downward" label={t('moveDown')} size="sm" variant="ghost" disabled={i === list.length - 1} onClick={() => move(i, 1)} />
              <IconButton icon="delete" label={t('remove')} size="sm" variant="danger" onClick={() => setList((l) => l.filter((_, j) => j !== i))} />
            </div>
          ) : null}
        </Card>
      ))}
      {canEdit ? (
        <div className="flex flex-wrap gap-2">
          <Button variant="secondary" iconLeft="add" disabled={list.length >= 10} onClick={() => setList((l) => [...l, { img: '', href: '/campaigns', alt: '' }])}>
            {t('addBanner')}
          </Button>
          <Button iconLeft="check" loading={pending} onClick={save}>
            {t('saveBanners')}
          </Button>
        </div>
      ) : null}
    </div>
  );
}
