'use client';

import { useEffect, useState } from 'react';
import { Button, Field, Input, RadioGroup, Select } from '@clipper/ui';
import { CAMPAIGN_TYPES, LIMITS } from '../constants';
import { Lock, Section, UploadButton } from '../parts';
import { coverPublicUrl, formatBytes } from '../upload';
import type { StepProps } from './shared';

export function BasicsStep({ draft, update, ctx, locked, t, locale, errorOf, upload, uploading }: StepProps) {
  const [preview, setPreview] = useState<string | null>(null);
  useEffect(() => () => {
    if (preview) URL.revokeObjectURL(preview);
  }, [preview]);

  const coverSrc = preview ?? coverPublicUrl(draft.cover?.storage_path);
  const titleLength = [...draft.title.trim()].length;

  const onCover = async (file: File) => {
    const asset = await upload('cover', file);
    if (!asset) return;
    setPreview(URL.createObjectURL(file));
    update((d) => ({ ...d, cover: asset }));
  };

  return (
    <Lock disabled={locked}>
      <Section title={t('basics.section')} description={t('stepHints.basics')}>
        <Field
          label={t('basics.title')}
          required
          helper={t('basics.titleHelper')}
          error={errorOf('title')}
          labelAside={
            <span className="tnum">
              {titleLength}/{LIMITS.titleMax}
            </span>
          }
        >
          <Input
            value={draft.title}
            maxLength={LIMITS.titleMax}
            placeholder={t('basics.titlePlaceholder')}
            autoComplete="off"
            onChange={(e) => {
              const title = e.target.value;
              update((d) => ({ ...d, title }));
            }}
          />
        </Field>

        <Field label={t('basics.category')} optional={t('common.optional')} error={errorOf('category_id')}>
          <Select
            value={draft.category_id ?? '__none'}
            onValueChange={(v) => update((d) => ({ ...d, category_id: v === '__none' ? null : v }))}
            options={[
              { value: '__none', label: t('basics.categoryNone') },
              ...ctx.categories.map((c) => ({ value: c.id, label: locale === 'en' ? c.name_en : c.name_id })),
            ]}
          />
        </Field>

        <div className="flex flex-col gap-1.5">
          <RadioGroup
            name="campaign-type"
            legend={t('basics.type')}
            legendVisible
            variant="card"
            value={draft.type}
            onValueChange={(v) => update((d) => ({ ...d, type: v as (typeof CAMPAIGN_TYPES)[number] }))}
            options={CAMPAIGN_TYPES.map((type) => ({ value: type, label: t(`types.${type}`), description: t(`typeHints.${type}`) }))}
            className="[&>div]:grid [&>div]:gap-2.5 sm:[&>div]:grid-cols-2"
          />
          {errorOf('type') ? (
            <p role="alert" className="text-caption font-medium text-danger-fg">
              {errorOf('type')}
            </p>
          ) : null}
        </div>

        <Field label={t('basics.slug')} optional={t('common.optional')} helper={t('basics.slugHelper')} error={errorOf('slug')}>
          <Input
            value={draft.slug}
            maxLength={80}
            placeholder={t('basics.slugPlaceholder')}
            autoCapitalize="none"
            autoComplete="off"
            spellCheck={false}
            onChange={(e) => {
              const slug = e.target.value.toLowerCase().replace(/\s+/g, '-');
              update((d) => ({ ...d, slug }));
            }}
          />
        </Field>
      </Section>

      <Section title={t('basics.cover')} description={t('basics.coverHelper')}>
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start">
          <div className="aspect-[16/9] w-full shrink-0 overflow-hidden rounded-card-sm border border-border bg-subtle sm:w-64">
            {coverSrc ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={coverSrc} alt={t('basics.coverAlt')} className="size-full object-cover" />
            ) : (
              <div className="grid size-full place-items-center p-4 text-center text-caption text-muted">
                {draft.cover ? draft.cover.name : t('basics.coverEmpty')}
              </div>
            )}
          </div>
          <div className="flex flex-col gap-2">
            {draft.cover ? (
              <p className="text-body-s text-text-2">
                <span className="font-semibold text-ink">{draft.cover.name}</span>
                {draft.cover.size_bytes != null ? ` · ${formatBytes(draft.cover.size_bytes, locale)}` : ''}
              </p>
            ) : null}
            <div className="flex flex-wrap gap-2">
              <UploadButton
                kind="cover"
                busy={!!uploading.cover}
                label={draft.cover ? t('basics.coverReplace') : t('basics.coverUpload')}
                onFile={(f) => void onCover(f)}
                icon="photo_camera"
              />
              {draft.cover ? (
                <Button
                  variant="ghost"
                  iconLeft="delete"
                  onClick={() => {
                    setPreview(null);
                    update((d) => ({ ...d, cover: null }));
                  }}
                >
                  {t('basics.coverRemove')}
                </Button>
              ) : null}
            </div>
            {errorOf('cover') ? (
              <p role="alert" className="text-caption font-medium text-danger-fg">
                {errorOf('cover')}
              </p>
            ) : null}
            <p className="text-caption text-muted">{t('basics.coverLimits')}</p>
          </div>
        </div>
      </Section>
    </Lock>
  );
}
