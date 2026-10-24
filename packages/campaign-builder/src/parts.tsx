'use client';

import { useEffect, useId, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { Button, Field, Icon, IconButton, Input, Spinner, Textarea, cn, formatNumber, type IconName } from '@clipper/ui';
import { displayItem, normalizeItem, splitChipInput, type ListKind } from './normalize';
import type { Locale, Translate } from './i18n';
import { acceptFor, formatBytes } from './upload';
import type { AssetDraft, FaqItem, UploadKind } from './types';

/* ───────────────────────── Section ───────────────────────── */

export function Section({ title, description, aside, children, className }: { title: ReactNode; description?: ReactNode; aside?: ReactNode; children: ReactNode; className?: string }) {
  const id = useId();
  return (
    <section aria-labelledby={id} className={cn('flex flex-col gap-4 border-t border-border pt-5 first:border-t-0 first:pt-0', className)}>
      <div className="flex items-start justify-between gap-3">
        <div className="flex min-w-0 flex-col gap-1">
          <h3 id={id} className="text-h6 text-ink">
            {title}
          </h3>
          {description ? <p className="text-body-s text-muted">{description}</p> : null}
        </div>
        {aside ? <div className="shrink-0">{aside}</div> : null}
      </div>
      {children}
    </section>
  );
}

/** Native fieldset reset: `disabled` disables every descendant control (used for the frozen brief). */
export function Lock({ disabled, children, className }: { disabled: boolean; children: ReactNode; className?: string }) {
  return (
    <fieldset disabled={disabled} className={cn('m-0 flex min-w-0 flex-col gap-6 border-0 p-0', className)}>
      {children}
    </fieldset>
  );
}

/* ───────────────────────── NumberField ───────────────────────── */

function parseNumber(text: string, decimals: number, locale: Locale): number | null {
  const raw = text.replace(/\s/g, '');
  if (raw === '') return null;
  let clean: string;
  if (decimals === 0) clean = raw.replace(/\D/g, '');
  else if (locale === 'id') clean = raw.replace(/\./g, '').replace(',', '.');
  else clean = raw.replace(/,/g, '');
  if (clean === '' || !/^\d*\.?\d*$/.test(clean) || clean === '.') return null;
  const n = Number(clean);
  return Number.isFinite(n) ? n : null;
}

export interface NumberFieldProps {
  label: ReactNode;
  value: number | null;
  onChange: (value: number | null) => void;
  locale: Locale;
  decimals?: number;
  helper?: ReactNode;
  error?: ReactNode;
  prefix?: ReactNode;
  suffix?: ReactNode;
  placeholder?: string;
  required?: boolean;
  optional?: boolean | ReactNode;
  labelHidden?: boolean;
  className?: string;
  inputSize?: 'sm' | 'md';
}

/** Numeric input with locale formatting on blur ("10.000.000"), tolerant parsing while typing. */
export function NumberField({ label, value, onChange, locale, decimals = 0, helper, error, prefix, suffix, placeholder, required, optional, labelHidden, className, inputSize }: NumberFieldProps) {
  const fmt = (v: number | null) => (v == null ? '' : formatNumber(v, locale, { maximumFractionDigits: decimals }));
  const [text, setText] = useState(() => fmt(value));
  const [focused, setFocused] = useState(false);
  useEffect(() => {
    if (!focused) setText(fmt(value));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value, focused, locale, decimals]);
  return (
    <Field label={label} helper={helper} error={error} required={required} optional={optional} labelHidden={labelHidden} className={className}>
      <Input
        inputMode={decimals > 0 ? 'decimal' : 'numeric'}
        autoComplete="off"
        value={text}
        placeholder={placeholder}
        prefix={prefix}
        suffix={suffix}
        inputSize={inputSize}
        inputClassName="tnum"
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        onChange={(e) => {
          setText(e.target.value);
          onChange(parseNumber(e.target.value, decimals, locale));
        }}
      />
    </Field>
  );
}

/* ───────────────────────── Chips / list input ───────────────────────── */

export interface ChipsFieldProps {
  label: ReactNode;
  kind: ListKind;
  values: string[];
  onChange: (values: string[]) => void;
  t: Translate;
  placeholder?: string;
  helper?: ReactNode;
  error?: ReactNode;
  /** chips (tags, links) or a vertical list (do/don't). */
  variant?: 'chips' | 'list';
  icon?: IconName;
  invalidMessage: string;
  disabled?: boolean;
}

/**
 * Add-as-you-type list. Enter / comma (tags) / "Tambah" adds; pasted lists are split; values are normalized like
 * market.norm_list (lowercase, no #/@, https). Backspace on an empty input removes the last chip.
 */
export function ChipsField({ label, kind, values, onChange, t, placeholder, helper, error, variant = 'chips', icon, invalidMessage, disabled }: ChipsFieldProps) {
  const [text, setText] = useState('');
  const [localError, setLocalError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const add = (raw: string) => {
    const parts = splitChipInput(kind, raw);
    if (parts.length === 0) return;
    const next = [...values];
    const rejected: string[] = [];
    for (const part of parts) {
      const { value, ok } = normalizeItem(kind, part);
      if (!ok) rejected.push(part);
      else if (value !== '' && !next.includes(value)) next.push(value);
    }
    if (next.length !== values.length) onChange(next);
    setText(rejected.join(kind === 'text' ? '\n' : ' '));
    setLocalError(rejected.length ? invalidMessage : null);
  };

  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter' || (e.key === ',' && kind !== 'text' && kind !== 'link')) {
      e.preventDefault();
      add(text);
    } else if (e.key === 'Backspace' && text === '' && values.length > 0 && variant === 'chips') {
      onChange(values.slice(0, -1));
    }
  };

  const shownError = localError ?? error;
  return (
    <Field label={label} helper={helper} error={shownError ?? undefined}>
      {(control) => (
        <div className="flex flex-col gap-2.5">
          <div className="flex gap-2">
            <Input
              ref={inputRef}
              {...control}
              invalid={control.invalid}
              iconLeft={icon}
              value={text}
              placeholder={placeholder}
              disabled={disabled}
              autoComplete="off"
              autoCapitalize={kind === 'text' ? 'sentences' : 'none'}
              spellCheck={kind === 'text'}
              onChange={(e) => {
                setText(e.target.value);
                if (localError) setLocalError(null);
              }}
              onKeyDown={onKeyDown}
              onBlur={() => {
                if (text.trim() && kind !== 'text') add(text);
              }}
              onPaste={(e) => {
                const pasted = e.clipboardData.getData('text');
                if (splitChipInput(kind, pasted).length > 1) {
                  e.preventDefault();
                  add(`${text} ${pasted}`);
                }
              }}
            />
            <Button variant="secondary" size="md" iconLeft="add" disabled={disabled || !text.trim()} onClick={() => add(text)} className="h-12 md:h-12">
              {t('chips.add')}
            </Button>
          </div>
          {values.length > 0 ? (
            variant === 'chips' ? (
              <ul className="flex flex-wrap gap-2" aria-label={typeof label === 'string' ? label : undefined}>
                {values.map((v) => (
                  <li key={v} className="inline-flex max-w-full items-center gap-1 rounded-full bg-primary-soft py-1 pr-1 pl-3 text-sm font-semibold text-primary-soft-fg">
                    <span className="truncate">{displayItem(kind, v)}</span>
                    <button
                      type="button"
                      disabled={disabled}
                      onClick={() => onChange(values.filter((x) => x !== v))}
                      aria-label={t('chips.remove', { value: displayItem(kind, v) })}
                      className="touch-target relative grid size-6 shrink-0 place-items-center rounded-full hover:bg-primary-soft-hover focus-ring disabled:hidden"
                    >
                      <Icon name="close" size={16} />
                    </button>
                  </li>
                ))}
              </ul>
            ) : (
              <ul className="flex flex-col divide-y divide-border rounded-card-sm border border-border">
                {values.map((v, i) => (
                  <li key={`${i}-${v}`} className="flex items-start gap-2 px-3 py-2 text-body-s text-ink">
                    <span className="min-w-0 flex-1 break-words pt-1">{v}</span>
                    <IconButton
                      variant="ghost"
                      size="sm"
                      icon="close"
                      disabled={disabled}
                      label={t('chips.remove', { value: v })}
                      onClick={() => onChange(values.filter((_, j) => j !== i))}
                    />
                  </li>
                ))}
              </ul>
            )
          ) : null}
        </div>
      )}
    </Field>
  );
}

/* ───────────────────────── FAQ ───────────────────────── */

export function FaqEditor({ faq, onChange, t, errorOf }: { faq: FaqItem[]; onChange: (faq: FaqItem[]) => void; t: Translate; errorOf: (field: string) => string | undefined }) {
  const set = (i: number, patch: Partial<FaqItem>) => onChange(faq.map((f, j) => (j === i ? { ...f, ...patch } : f)));
  return (
    <div className="flex flex-col gap-3">
      {faq.length === 0 ? <p className="text-body-s text-muted">{t('brief.faqEmpty')}</p> : null}
      <ol className="flex flex-col gap-3">
        {faq.map((f, i) => (
          <li key={i} className="flex flex-col gap-3 rounded-card-sm border border-border bg-surface-2 p-3">
            <div className="flex items-center justify-between gap-2">
              <span className="text-caption font-bold text-muted">{t('brief.faqItem', { n: i + 1 })}</span>
              <IconButton variant="ghost" size="sm" icon="delete" label={t('brief.faqRemove', { n: i + 1 })} onClick={() => onChange(faq.filter((_, j) => j !== i))} />
            </div>
            <Field label={t('brief.faqQ')} error={errorOf(`faq.${i}.q`)}>
              <Input value={f.q} maxLength={300} onChange={(e) => set(i, { q: e.target.value })} />
            </Field>
            <Field label={t('brief.faqA')} error={errorOf(`faq.${i}.a`)}>
              <Textarea value={f.a} rows={2} maxLength={2000} onChange={(e) => set(i, { a: e.target.value })} />
            </Field>
          </li>
        ))}
      </ol>
      <div>
        <Button variant="tertiary" size="md" iconLeft="add" onClick={() => onChange([...faq, { q: '', a: '' }])}>
          {t('brief.faqAdd')}
        </Button>
      </div>
    </div>
  );
}

/* ───────────────────────── Upload ───────────────────────── */

export function UploadButton({
  kind,
  label,
  busy,
  disabled,
  onFile,
  variant = 'secondary',
  icon = 'upload',
}: {
  kind: UploadKind;
  label: ReactNode;
  busy: boolean;
  disabled?: boolean;
  onFile: (file: File) => void;
  variant?: 'secondary' | 'tertiary' | 'primary';
  icon?: IconName;
}) {
  const ref = useRef<HTMLInputElement>(null);
  return (
    <>
      <input
        ref={ref}
        type="file"
        accept={acceptFor(kind)}
        className="sr-only"
        tabIndex={-1}
        aria-hidden
        disabled={disabled || busy}
        onChange={(e) => {
          const file = e.target.files?.[0];
          e.target.value = '';
          if (file) onFile(file);
        }}
      />
      <Button variant={variant} iconLeft={icon} loading={busy} disabled={disabled} onClick={() => ref.current?.click()}>
        {label}
      </Button>
    </>
  );
}

const ASSET_ICON: Record<AssetDraft['kind'], IconName> = {
  cover: 'image',
  video: 'movie',
  image: 'image',
  audio: 'music_note',
  document: 'description',
  link: 'link',
};

export function AssetList({ items, onRemove, t, locale, emptyText }: { items: AssetDraft[]; onRemove: (key: string) => void; t: Translate; locale: Locale; emptyText: string }) {
  if (items.length === 0) return <p className="text-body-s text-muted">{emptyText}</p>;
  return (
    <ul className="flex flex-col divide-y divide-border rounded-card-sm border border-border">
      {items.map((a) => (
        <li key={a.key} className="flex items-center gap-3 px-3 py-2.5">
          <span className="grid size-9 shrink-0 place-items-center rounded-chip bg-subtle text-text-2">
            <Icon name={ASSET_ICON[a.kind]} size={20} />
          </span>
          <span className="flex min-w-0 flex-1 flex-col">
            <span className="truncate text-sm font-semibold text-ink">{a.name ?? a.url ?? a.storage_path}</span>
            <span className="text-caption text-muted">
              {t(`assetKinds.${a.kind}`)}
              {a.size_bytes != null ? ` · ${formatBytes(a.size_bytes, locale)}` : ''}
            </span>
          </span>
          <IconButton variant="ghost" size="sm" icon="delete" label={t('brief.assetRemove', { name: a.name ?? '' })} onClick={() => onRemove(a.key)} />
        </li>
      ))}
    </ul>
  );
}

export function InlineSpinner({ label }: { label: string }) {
  return (
    <span className="inline-flex items-center gap-2 text-caption text-muted" role="status">
      <Spinner size={14} />
      {label}
    </span>
  );
}

/* ───────────────────────── Option cards (checkbox grid) ───────────────────────── */

export function ToggleCard({ checked, onChange, children, disabled, description }: { checked: boolean; onChange: (v: boolean) => void; children: ReactNode; description?: ReactNode; disabled?: boolean }) {
  const id = useId();
  return (
    <label
      htmlFor={id}
      className={cn(
        'flex min-h-14 cursor-pointer items-center gap-3 rounded-card-sm border-[1.5px] border-border-strong bg-surface p-3 transition-[border-color,background-color,box-shadow] duration-120',
        'hover:border-border-hover has-[:checked]:border-primary has-[:checked]:bg-brand-50 dark:has-[:checked]:bg-primary-soft',
        'has-[:focus-visible]:shadow-[0_0_0_4px_var(--color-focus-halo)] has-[:disabled]:cursor-not-allowed has-[:disabled]:opacity-60',
      )}
    >
      <input id={id} type="checkbox" className="peer sr-only" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} />
      <span className="flex min-w-0 flex-1 flex-col">
        <span className="flex items-center gap-2 text-sm font-bold text-ink">{children}</span>
        {description ? <span className="text-caption text-muted">{description}</span> : null}
      </span>
      <span
        aria-hidden
        className="grid size-[22px] shrink-0 place-items-center rounded-[7px] border-[1.5px] border-border-hover text-white peer-checked:border-0 peer-checked:bg-cta"
      >
        {checked ? <Icon name="check" size={18} /> : null}
      </span>
    </label>
  );
}
