'use client';

import { useState, useTransition, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import {
  Alert,
  Button,
  Checkbox,
  CopyField,
  Dialog,
  DialogContent,
  DialogTrigger,
  Field,
  Fieldset,
  IconButton,
  Input,
  RadioGroup,
  Select,
  toast,
} from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { saveRewardType, type RewardTypeInput } from './actions';

export interface RewardTypeRow {
  id: string;
  code: string;
  name: string;
  kind: string;
  unit_label: string;
  idr_value_per_unit: number;
  decimals: number;
  fulfillment: string;
  recipient_schema: { key: string; label: string; pii: boolean; required: boolean }[];
  stock: number | null;
}

const KINDS = ['in_game', 'voucher_code', 'points', 'physical', 'custom'] as const;
const FULFILLMENTS = ['manual_export', 'code_pool', 'webhook'] as const;
const CODE_RE = /^[A-Z0-9_]{2,40}$/;
const KEY_RE = /^[a-z][a-z0-9_]{1,39}$/;

type Draft = Omit<RewardTypeInput, 'idr_value_per_unit' | 'decimals' | 'stock'> & { idr: string; decimals: string; stock: string };

const toDraft = (r?: RewardTypeRow): Draft => ({
  id: r?.id,
  name: r?.name ?? '',
  code: r?.code ?? '',
  kind: r?.kind ?? 'in_game',
  unit_label: r?.unit_label ?? '',
  idr: r ? String(r.idr_value_per_unit) : '',
  decimals: String(r?.decimals ?? 0),
  fulfillment: (FULFILLMENTS as readonly string[]).includes(r?.fulfillment ?? '') ? (r!.fulfillment as Draft['fulfillment']) : 'manual_export',
  recipient_schema: r?.recipient_schema ?? [],
  stock: r?.stock == null ? '' : String(r.stock),
  webhook_url: '',
  rotate_secret: false,
});

export function RewardTypeDialog({ orgId, row, trigger }: { orgId: string; row?: RewardTypeRow; trigger: ReactNode }) {
  const t = useTranslations('brand.rewardTypes');
  const errText = useErrorText();
  const [open, setOpen] = useState(false);
  const [d, setD] = useState<Draft>(() => toDraft(row));
  const [secret, setSecret] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => setD((cur) => ({ ...cur, [k]: v }));
  const idr = Number(d.idr);
  const decimals = Number(d.decimals);
  const stock = d.stock.trim() === '' ? null : Number(d.stock);
  const wasWebhook = row?.fulfillment === 'webhook';
  const needsUrl = d.fulfillment === 'webhook' && !wasWebhook;
  const issues = {
    name: d.name.trim().length < 2,
    code: !CODE_RE.test(d.code.trim().toUpperCase()),
    unit: !d.unit_label.trim(),
    idr: !(idr > 0),
    decimals: !(Number.isInteger(decimals) && decimals >= 0 && decimals <= 6),
    stock: stock != null && !(stock >= 0),
    url: d.fulfillment === 'webhook' && (needsUrl || d.webhook_url) ? !/^https:\/\/\S+$/.test(d.webhook_url ?? '') : false,
    fields: d.recipient_schema.some((f) => !KEY_RE.test(f.key) || !f.label.trim()),
  };
  const invalid = Object.values(issues).some(Boolean);
  const [touched, setTouched] = useState(false);
  const err = (k: keyof typeof issues) => (touched && issues[k] ? t(`invalid.${k}`) : undefined);

  const reset = (o: boolean) => {
    setOpen(o);
    if (o) {
      setD(toDraft(row));
      setSecret(null);
      setError(null);
      setTouched(false);
    }
  };

  const submit = () => {
    setTouched(true);
    if (invalid) return;
    start(async () => {
      const res = await saveRewardType(orgId, { ...d, idr_value_per_unit: idr, decimals, stock });
      if (!res.ok) return setError(errText(res.error));
      toast.success(t('saved'));
      if (res.secret) setSecret(res.secret);
      else setOpen(false);
    });
  };

  const fieldRow = (i: number, patch: Partial<Draft['recipient_schema'][number]>) =>
    set('recipient_schema', d.recipient_schema.map((f, j) => (j === i ? { ...f, ...patch } : f)));

  return (
    <Dialog open={open} onOpenChange={reset}>
      <DialogTrigger asChild>{trigger}</DialogTrigger>
      <DialogContent
        size="lg"
        title={secret ? t('secretTitle') : row ? t('editTitle', { name: row.name }) : t('createTitle')}
        description={secret ? t('secretBody') : t('formHint')}
        footer={
          secret ? (
            <Button onClick={() => setOpen(false)}>{t('secretDone')}</Button>
          ) : (
            <>
              <Button variant="secondary" onClick={() => setOpen(false)}>{t('cancel')}</Button>
              <Button loading={pending} onClick={submit}>{t('save')}</Button>
            </>
          )
        }
      >
        {secret ? (
          <CopyField value={secret} label={t('secretLabel')} mono copyLabel={t('copy')} copiedLabel={t('copied')} />
        ) : (
          <form
            className="flex flex-col gap-4"
            onSubmit={(e) => {
              e.preventDefault();
              submit();
            }}
          >
            {error ? <Alert tone="danger">{error}</Alert> : null}
            {row ? <Alert tone="info">{t('lockedNote')}</Alert> : null}
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label={t('name')} error={err('name')} required>
                <Input value={d.name} onChange={(e) => set('name', e.target.value)} maxLength={80} />
              </Field>
              <Field label={t('code')} helper={t('codeHelp')} error={err('code')} required>
                <Input value={d.code} onChange={(e) => set('code', e.target.value.toUpperCase())} maxLength={40} inputClassName="font-mono uppercase" />
              </Field>
              <Field label={t('kind')} required>
                <Select value={d.kind} onValueChange={(v) => set('kind', v)} options={KINDS.map((k) => ({ value: k, label: t(`kinds.${k}`) }))} />
              </Field>
              <Field label={t('unitLabel')} helper={t('unitHelp')} error={err('unit')} required>
                <Input value={d.unit_label} onChange={(e) => set('unit_label', e.target.value)} maxLength={30} />
              </Field>
              <Field label={t('idrValue')} helper={t('idrHelp')} error={err('idr')} required>
                <Input type="number" inputMode="decimal" min={0} step="any" prefix="Rp" value={d.idr} onChange={(e) => set('idr', e.target.value)} />
              </Field>
              <Field label={t('decimals')} helper={t('decimalsHelp')} error={err('decimals')} required>
                <Input type="number" inputMode="numeric" min={0} max={6} step={1} value={d.decimals} onChange={(e) => set('decimals', e.target.value)} />
              </Field>
              <Field label={t('stock')} helper={t('stockHelp')} error={err('stock')} optional={t('optional')}>
                <Input type="number" inputMode="decimal" min={0} step="any" value={d.stock} onChange={(e) => set('stock', e.target.value)} />
              </Field>
            </div>
            <RadioGroup
              name="fulfillment"
              legend={t('fulfillment')}
              legendVisible
              variant="card"
              value={d.fulfillment}
              onValueChange={(v) => set('fulfillment', v as Draft['fulfillment'])}
              options={FULFILLMENTS.map((f) => ({ value: f, label: t(`fulfillments.${f}`), description: t(`fulfillmentHelp.${f}`) }))}
            />
            {d.fulfillment === 'webhook' ? (
              <div className="flex flex-col gap-3">
                <Field label={t('webhookUrl')} helper={wasWebhook ? t('webhookKeep') : t('webhookHelp')} error={err('url')} required={needsUrl}>
                  <Input type="url" inputMode="url" placeholder="https://" value={d.webhook_url ?? ''} onChange={(e) => set('webhook_url', e.target.value)} />
                </Field>
                {wasWebhook ? (
                  <Checkbox checked={!!d.rotate_secret} onCheckedChange={(v) => set('rotate_secret', v === true)} label={t('rotateSecret')} description={t('rotateHelp')} />
                ) : (
                  <p className="text-caption text-muted">{t('secretOnce')}</p>
                )}
              </div>
            ) : null}
            <Fieldset legend={t('recipientFields')} description={t('recipientHelp')} error={touched && issues.fields ? t('invalid.fields') : undefined}>
              <ul className="flex flex-col gap-3">
                {d.recipient_schema.map((f, i) => (
                  <li key={i} className="grid gap-2 rounded-card-sm border border-border p-3 sm:grid-cols-[1fr_1fr_auto]">
                    <Field label={t('fieldLabel')}>
                      <Input inputSize="sm" value={f.label} onChange={(e) => fieldRow(i, { label: e.target.value })} placeholder={t('fieldLabelPh')} />
                    </Field>
                    <Field label={t('fieldKey')}>
                      <Input inputSize="sm" value={f.key} onChange={(e) => fieldRow(i, { key: e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '_') })} inputClassName="font-mono" placeholder="game_id" />
                    </Field>
                    <IconButton icon="delete" label={t('removeField', { label: f.label || f.key || i + 1 })} variant="ghost" className="self-end" onClick={() => set('recipient_schema', d.recipient_schema.filter((_, j) => j !== i))} />
                    <div className="flex flex-wrap gap-4 sm:col-span-3">
                      <Checkbox checked={f.required} onCheckedChange={(v) => fieldRow(i, { required: v === true })} label={t('fieldRequired')} />
                      <Checkbox checked={f.pii} onCheckedChange={(v) => fieldRow(i, { pii: v === true })} label={t('fieldPii')} description={t('fieldPiiHelp')} />
                    </div>
                  </li>
                ))}
              </ul>
              <Button
                variant="tertiary"
                size="sm"
                iconLeft="add"
                className="mt-2 self-start"
                onClick={() => set('recipient_schema', [...d.recipient_schema, { key: '', label: '', pii: false, required: true }])}
              >
                {t('addField')}
              </Button>
            </Fieldset>
          </form>
        )}
      </DialogContent>
    </Dialog>
  );
}
