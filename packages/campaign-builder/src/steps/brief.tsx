'use client';

import { useState } from 'react';
import { Alert, Badge, Button, Field, Input, RadioGroup, Switch, Tabs, TabsContent, TabsList, TabsTrigger, Textarea } from '@clipper/ui';
import { idr } from '../i18n';
import { SafeMarkdown } from '../markdown';
import { newKey } from '../model';
import { normalizeLink } from '../normalize';
import { AssetList, ChipsField, FaqEditor, Lock, NumberField, Section, UploadButton } from '../parts';
import type { StepProps } from './shared';

function BriefEditor({ value, onChange, label, helper, error, t, rows = 10 }: { value: string; onChange: (v: string) => void; label: string; helper: string; error?: string; t: StepProps['t']; rows?: number }) {
  const [tab, setTab] = useState('write');
  return (
    <Tabs value={tab} onValueChange={setTab} className="gap-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <span className="text-label text-ink">{label}</span>
        <TabsList variant="pill" aria-label={label}>
          <TabsTrigger value="write" icon="edit">
            {t('brief.write')}
          </TabsTrigger>
          <TabsTrigger value="preview" icon="visibility">
            {t('brief.preview')}
          </TabsTrigger>
        </TabsList>
      </div>
      <TabsContent value="write">
        <Field label={label} labelHidden helper={helper} error={error}>
          <Textarea value={value} rows={rows} maxLength={20000} onChange={(e) => onChange(e.target.value)} placeholder={t('brief.textPlaceholder')} />
        </Field>
      </TabsContent>
      <TabsContent value="preview">
        <div className="min-h-40 rounded-control border-[1.5px] border-border bg-surface-2 p-4">
          <SafeMarkdown source={value} empty={<p className="text-body-s text-muted">{t('brief.previewEmpty')}</p>} />
        </div>
        <p className="mt-1.5 text-caption text-muted">{t('brief.previewNote')}</p>
      </TabsContent>
    </Tabs>
  );
}

export function BriefStep({ draft, update, ctx, locked, t, locale, errorOf, upload, uploading }: StepProps) {
  const [link, setLink] = useState('');
  const [linkError, setLinkError] = useState<string | null>(null);
  const managed = draft.service_mode === 'managed';
  const brandMode = ctx.mode === 'brand';

  const addLink = () => {
    const { value, ok } = normalizeLink(link);
    if (!value) return;
    if (!ok) {
      setLinkError(t('errors.linkHttps'));
      return;
    }
    setLinkError(null);
    setLink('');
    let host = value;
    try {
      host = new URL(value).host;
    } catch {
      /* keep raw */
    }
    update((d) =>
      d.assets.some((a) => a.url === value)
        ? d
        : { ...d, assets: [...d.assets, { key: newKey('asset'), id: null, kind: 'link', audience: 'clipper', storage_path: null, url: value, size_bytes: null, name: host }] },
    );
  };

  const onAsset = async (file: File, kind: 'asset' | 'internal') => {
    const asset = await upload(kind, file);
    if (!asset) return;
    update((d) => (kind === 'internal' ? { ...d, internal_files: [...d.internal_files, asset] } : { ...d, assets: [...d.assets, asset] }));
  };

  return (
    <div className="flex flex-col gap-6">
      <Lock disabled={locked}>
        {brandMode ? (
          <Section title={t('brief.modeLegend')} description={t('stepHints.brief')}>
            <RadioGroup
              name="service-mode"
              legend={t('brief.modeLegend')}
              variant="card"
              value={draft.service_mode}
              onValueChange={(v) => update((d) => ({ ...d, service_mode: v === 'managed' ? 'managed' : 'self_serve' }))}
              options={[
                { value: 'self_serve', label: t('brief.modeSelf'), description: t('brief.modeSelfHint') },
                {
                  value: 'managed',
                  label: t('brief.modeManaged'),
                  description: t('brief.modeManagedHint'),
                  aside: idr(ctx.managedServiceIdr, locale),
                },
              ]}
            />
          </Section>
        ) : managed ? (
          <Alert tone="info" title={t('banner.managedAdminTitle')}>
            {t('banner.managedAdminBody')}
          </Alert>
        ) : null}

        {managed && brandMode ? (
          <Section title={t('brief.managedSection')} description={t('brief.managedSectionHint')} aside={<Badge tone="primary" icon="support_agent">{t('brief.modeManaged')}</Badge>}>
            <BriefEditor
              label={t('brief.rawBrief')}
              helper={t('brief.rawBriefHelper')}
              value={draft.managed_brief}
              error={errorOf('managed_brief')}
              onChange={(managed_brief) => update((d) => ({ ...d, managed_brief }))}
              t={t}
              rows={8}
            />
            <div className="flex flex-col gap-2.5">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="flex flex-col">
                  <span className="text-label text-ink">{t('brief.internalFiles')}</span>
                  <span className="text-caption text-muted">{t('brief.internalFilesHelper')}</span>
                </div>
                <UploadButton kind="internal" busy={!!uploading.internal} label={t('brief.internalUpload')} onFile={(f) => void onAsset(f, 'internal')} />
              </div>
              <AssetList
                items={draft.internal_files}
                t={t}
                locale={locale}
                emptyText={t('brief.internalEmpty')}
                onRemove={(key) => update((d) => ({ ...d, internal_files: d.internal_files.filter((a) => a.key !== key) }))}
              />
              {errorOf('internal_files', true) ? (
                <p role="alert" className="text-caption font-medium text-danger-fg">
                  {errorOf('internal_files', true)}
                </p>
              ) : null}
            </div>
          </Section>
        ) : null}

        <Section title={managed && brandMode ? t('brief.structuredOptional') : t('brief.structured')} description={managed && brandMode ? t('brief.structuredOptionalHint') : undefined}>
          {!(managed && brandMode) ? (
            <BriefEditor label={t('brief.text')} helper={t('brief.textHelper')} value={draft.brief} error={errorOf('brief')} onChange={(brief) => update((d) => ({ ...d, brief }))} t={t} />
          ) : null}
          <div className="grid gap-5 md:grid-cols-2">
            <ChipsField
              label={t('brief.dos')}
              kind="text"
              variant="list"
              icon="check_circle"
              values={draft.dos}
              onChange={(dos) => update((d) => ({ ...d, dos }))}
              placeholder={t('brief.dosPlaceholder')}
              invalidMessage={t('errors.required')}
              error={errorOf('dos', true)}
              t={t}
            />
            <ChipsField
              label={t('brief.donts')}
              kind="text"
              variant="list"
              icon="block"
              values={draft.donts}
              onChange={(donts) => update((d) => ({ ...d, donts }))}
              placeholder={t('brief.dontsPlaceholder')}
              invalidMessage={t('errors.required')}
              error={errorOf('donts', true)}
              t={t}
            />
          </div>
          <ChipsField
            label={t('brief.examples')}
            kind="link"
            icon="play_circle"
            values={draft.example_urls}
            onChange={(example_urls) => update((d) => ({ ...d, example_urls }))}
            placeholder={t('brief.examplesPlaceholder')}
            helper={t('brief.examplesHelper')}
            invalidMessage={t('errors.linkHttps')}
            error={errorOf('example_urls', true)}
            t={t}
          />
        </Section>

        <Section title={t('brief.requiredSection')} description={t('brief.requiredSectionHint')}>
          <ChipsField
            label={t('brief.hashtags')}
            kind="hashtag"
            icon="tag"
            values={draft.required_hashtags}
            onChange={(required_hashtags) => update((d) => ({ ...d, required_hashtags }))}
            placeholder={t('brief.hashtagsPlaceholder')}
            helper={t('brief.hashtagsHelper')}
            invalidMessage={t('errors.hashtag')}
            error={errorOf('required_hashtags', true)}
            t={t}
          />
          <ChipsField
            label={t('brief.mentions')}
            kind="mention"
            icon="alternate_email"
            values={draft.required_mentions}
            onChange={(required_mentions) => update((d) => ({ ...d, required_mentions }))}
            placeholder={t('brief.mentionsPlaceholder')}
            invalidMessage={t('errors.mention')}
            error={errorOf('required_mentions', true)}
            t={t}
          />
          <ChipsField
            label={t('brief.links')}
            kind="link"
            icon="link"
            values={draft.required_links}
            onChange={(required_links) => update((d) => ({ ...d, required_links }))}
            placeholder={t('brief.linksPlaceholder')}
            helper={t('brief.linksHelper')}
            invalidMessage={t('errors.linkHttps')}
            error={errorOf('required_links', true)}
            t={t}
          />
          <div className="grid grid-cols-2 gap-3">
            <NumberField
              label={t('brief.durationMin')}
              value={draft.min_duration_sec}
              onChange={(min_duration_sec) => update((d) => ({ ...d, min_duration_sec }))}
              locale={locale}
              suffix={t('common.seconds')}
              optional={t('common.optional')}
              error={errorOf('min_duration_sec')}
            />
            <NumberField
              label={t('brief.durationMax')}
              value={draft.max_duration_sec}
              onChange={(max_duration_sec) => update((d) => ({ ...d, max_duration_sec }))}
              locale={locale}
              suffix={t('common.seconds')}
              optional={t('common.optional')}
              error={errorOf('max_duration_sec')}
            />
          </div>
          <p className="-mt-2 text-caption text-muted">{t('brief.durationHelper')}</p>
          <Switch
            label={t('brief.sponsored')}
            description={t('brief.sponsoredHint')}
            checked={draft.sponsored_label}
            onCheckedChange={(sponsored_label) => update((d) => ({ ...d, sponsored_label }))}
          />
        </Section>

        <Section title={t('brief.assets')} description={t('brief.assetsHelper')}>
          <div className="flex flex-wrap gap-2">
            <UploadButton kind="asset" busy={!!uploading.asset} label={t('brief.assetUpload')} onFile={(f) => void onAsset(f, 'asset')} />
          </div>
          <Field label={t('brief.assetLink')} helper={t('brief.assetLinkHelper')} error={linkError ?? undefined}>
            {(control) => (
              <div className="flex gap-2">
                <Input
                  {...control}
                  invalid={control.invalid}
                  iconLeft="link"
                  value={link}
                  inputMode="url"
                  autoCapitalize="none"
                  placeholder={t('brief.assetLinkPlaceholder')}
                  onChange={(e) => {
                    setLink(e.target.value);
                    setLinkError(null);
                  }}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') {
                      e.preventDefault();
                      addLink();
                    }
                  }}
                />
                <Button variant="secondary" iconLeft="add_link" disabled={!link.trim()} onClick={addLink} className="h-12 md:h-12">
                  {t('chips.add')}
                </Button>
              </div>
            )}
          </Field>
          <AssetList
            items={draft.assets}
            t={t}
            locale={locale}
            emptyText={t('brief.assetsEmpty')}
            onRemove={(key) => update((d) => ({ ...d, assets: d.assets.filter((a) => a.key !== key) }))}
          />
          {errorOf('assets', true) ? (
            <p role="alert" className="text-caption font-medium text-danger-fg">
              {errorOf('assets', true)}
            </p>
          ) : null}
        </Section>
      </Lock>

      {/* FAQ stays editable after submission (save_campaign accepts only faq once in_review). */}
      <Section title={t('brief.faq')} description={locked ? t('brief.faqLockedHint') : t('brief.faqHelper')}>
        <FaqEditor faq={draft.faq} onChange={(faq) => update((d) => ({ ...d, faq }))} t={t} errorOf={(f) => errorOf(f)} />
      </Section>
    </div>
  );
}
