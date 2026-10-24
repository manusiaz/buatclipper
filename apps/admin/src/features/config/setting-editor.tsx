'use client';

import { useId, useState, useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, Dialog, DialogContent, Field, Input, Switch, Textarea, toast } from '@clipper/ui';
import { useErrorText } from '@/features/shared/use-error-text';
import { updateConfig } from './actions';
import { diff, editorKind, parseJson, parseScalar, type Json } from './value';

const show = (v: Json | undefined): string =>
  v === undefined ? '—' : typeof v === 'string' ? (v === '' ? '""' : v) : JSON.stringify(v);
/** Ringkasan nilai di baris: object datar → "kunci: nilai · …", selebihnya JSON. */
const summary = (v: Json) =>
  v && typeof v === 'object' && !Array.isArray(v) && Object.values(v).every((x) => x === null || typeof x !== 'object')
    ? Object.entries(v).map(([k, x]) => `${k}: ${show(x)}`).join(' · ') || '{}'
    : show(v);

/** Satu baris config: nilai sekarang + editor bertipe → konfirmasi diff sebelum/sesudah → api.update_config. */
export function SettingEditor({ settingKey, label, value, canEdit }: { settingKey: string; label: string; value: Json; canEdit: boolean }) {
  const t = useTranslations('admin.config');
  const tc = useTranslations('common');
  const errorText = useErrorText();
  const formId = useId();
  const kind = editorKind(value);
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState<Record<string, string | boolean>>({});
  const [next, setNext] = useState<Json | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const reset = () => {
    const obj = (value ?? {}) as Record<string, Json>;
    setDraft(
      kind === 'flags' || kind === 'fields'
        ? Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, typeof v === 'boolean' ? v : String(v)]))
        : { v: kind === 'boolean' ? (value as boolean) : kind === 'json' ? JSON.stringify(value, null, 2) : String(value) },
    );
    setNext(null);
    setError(null);
  };

  const build = (): Json | undefined => {
    if (kind === 'boolean') return draft.v as boolean;
    if (kind === 'number' || kind === 'string') return parseScalar(String(draft.v ?? ''), value);
    if (kind === 'json') return parseJson(String(draft.v ?? ''), value);
    const obj = value as Record<string, Json>;
    const out: Record<string, Json> = {};
    for (const [k, v] of Object.entries(obj)) {
      const p = typeof v === 'boolean' ? (draft[k] as boolean) : parseScalar(String(draft[k] ?? ''), v);
      if (p === undefined) return undefined;
      out[k] = p;
    }
    return out;
  };

  const changes = next === null ? [] : diff(value, next);

  return (
    <div className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:gap-4">
      <div className="min-w-0 flex-1">
        <p className="text-sm font-semibold text-ink">{label}</p>
        <code className="block font-mono text-[11px] text-faint">{settingKey}</code>
      </div>
      <code className="max-w-full font-mono text-caption break-all text-text-2 sm:max-w-[45%] sm:text-right">{summary(value)}</code>
      {canEdit ? (
        <Button
          size="sm"
          variant="tertiary"
          iconLeft="edit"
          onClick={() => {
            reset();
            setOpen(true);
          }}
        >
          {t('edit')}
        </Button>
      ) : null}
      <Dialog open={open} onOpenChange={(v) => !pending && setOpen(v)}>
        <DialogContent
          size="md"
          title={label}
          description={settingKey}
          closeLabel={tc('close')}
          footer={
            next === null ? (
              <>
                <Button variant="secondary" onClick={() => setOpen(false)}>
                  {tc('cancel')}
                </Button>
                <Button type="submit" form={formId}>
                  {t('review')}
                </Button>
              </>
            ) : (
              <>
                <Button variant="secondary" disabled={pending} onClick={() => setNext(null)}>
                  {tc('back')}
                </Button>
                <Button
                  variant="ink"
                  loading={pending}
                  disabled={changes.length === 0}
                  onClick={() =>
                    start(async () => {
                      const r = await updateConfig(settingKey, next);
                      if (!r.ok) return setError(errorText(r.error));
                      toast.success(t('saved'));
                      setOpen(false);
                    })
                  }
                >
                  {t('apply')}
                </Button>
              </>
            )
          }
        >
          {error ? <Alert tone="danger" className="mb-3">{error}</Alert> : null}
          {next === null ? (
            <form
              id={formId}
              className="flex flex-col gap-4"
              onSubmit={(e) => {
                e.preventDefault();
                const v = build();
                if (v === undefined) return setError(t('invalidValue'));
                setError(null);
                setNext(v);
              }}
            >
              {kind === 'boolean' ? (
                <Switch label={label} checked={draft.v as boolean} onCheckedChange={(v) => setDraft({ v })} />
              ) : kind === 'number' || kind === 'string' ? (
                <Field label={t('value')}>
                  {String(draft.v ?? '').length > 80 ? (
                    <Textarea rows={4} value={String(draft.v ?? '')} onChange={(e) => setDraft({ v: e.target.value })} />
                  ) : (
                    <Input inputMode={kind === 'number' ? 'decimal' : undefined} value={String(draft.v ?? '')} onChange={(e) => setDraft({ v: e.target.value })} />
                  )}
                </Field>
              ) : kind === 'json' ? (
                <Field label={t('valueJson')} helper={t('valueJsonHelp')}>
                  <Textarea rows={8} className="font-mono" value={String(draft.v ?? '')} onChange={(e) => setDraft({ v: e.target.value })} />
                </Field>
              ) : (
                Object.entries(value as Record<string, Json>).map(([k, v]) =>
                  typeof v === 'boolean' ? (
                    <Switch key={k} label={k} checked={draft[k] as boolean} onCheckedChange={(x) => setDraft((d) => ({ ...d, [k]: x }))} />
                  ) : (
                    <Field key={k} label={k}>
                      <Input inputMode={typeof v === 'number' ? 'decimal' : undefined} value={String(draft[k] ?? '')} onChange={(e) => setDraft((d) => ({ ...d, [k]: e.target.value }))} />
                    </Field>
                  ),
                )
              )}
            </form>
          ) : changes.length === 0 ? (
            <p className="text-body-s text-muted">{t('noChange')}</p>
          ) : (
            <div className="flex flex-col gap-2">
              <p className="text-label text-ink">{t('diffTitle')}</p>
              <ul className="flex flex-col gap-2">
                {changes.map((c) => (
                  <li key={c.path} className="rounded-card-sm bg-subtle p-3 text-body-s">
                    {c.path !== '·' ? <p className="font-mono text-caption text-muted">{c.path}</p> : null}
                    <p className="font-mono break-all text-danger-fg line-through">{show(c.before)}</p>
                    <p className="font-mono break-all text-success-fg">{show(c.after)}</p>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </DialogContent>
      </Dialog>
    </div>
  );
}
