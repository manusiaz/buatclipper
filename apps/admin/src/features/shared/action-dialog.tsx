'use client';

// Aksi admin generik: halaman server mengirim Server Action ter-bind (id sudah terikat) + deskripsi field; dialog mengirim
// FormData, menahan dialog tetap terbuka saat gagal dan menampilkan error yang sudah dipetakan.
import { useId, useState, useTransition, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import {
  Alert, Button, Checkbox, Dialog, DialogContent, DialogTrigger, Field, Input, Select, Textarea, toast,
  type ButtonSize, type ButtonVariant, type IconName,
} from '@clipper/ui';
import type { ActionResult } from '@/lib/action';
import { useErrorText } from './use-error-text';

type Base = { name: string; label: string; helper?: string; required?: boolean };
export type FieldSpec =
  | (Base & {
      kind: 'text' | 'textarea' | 'number' | 'datetime' | 'date' | 'email';
      defaultValue?: string;
      placeholder?: string;
      min?: number;
      max?: number;
      step?: string;
      maxLength?: number;
      prefix?: string;
      suffix?: string;
    })
  | (Base & { kind: 'select'; options: { value: string; label: string }[]; defaultValue?: string })
  | (Base & { kind: 'checkbox'; defaultChecked?: boolean })
  | (Base & { kind: 'file'; accept?: string; maxBytes?: number });

export interface TriggerSpec {
  label: string;
  variant?: ButtonVariant;
  size?: ButtonSize;
  icon?: IconName;
  disabled?: boolean;
}

export type AdminAction = (fd: FormData) => Promise<ActionResult<unknown>>;

export interface ActionDialogProps {
  trigger: TriggerSpec;
  title: string;
  description?: string;
  fields?: FieldSpec[];
  submitLabel: string;
  tone?: 'primary' | 'danger' | 'ink';
  success: string;
  action: AdminAction;
  /** Konten tambahan di atas field (ringkasan, diff). */
  children?: ReactNode;
  size?: 'sm' | 'md' | 'lg';
}

export function ActionDialog({ trigger, title, description, fields = [], submitLabel, tone = 'primary', success, action, children, size = 'sm' }: ActionDialogProps) {
  const tc = useTranslations('common');
  const ta = useTranslations('admin');
  const errorText = useErrorText();
  const formId = useId();
  const [open, setOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const submit = (form: HTMLFormElement) => {
    const fd = new FormData(form);
    for (const f of fields) {
      const v = fd.get(f.name);
      if (f.kind === 'file' && v instanceof File && f.maxBytes && v.size > f.maxBytes) return setError(ta('form.fileTooBig'));
      if (f.required && f.kind !== 'checkbox' && (v == null || (typeof v === 'string' && !v.trim()) || (v instanceof File && v.size === 0))) {
        return setError(ta('form.required', { field: f.label }));
      }
    }
    setError(null);
    start(async () => {
      const r = await action(fd);
      if (!r.ok) return setError(errorText(r.error));
      toast.success(success);
      setOpen(false);
    });
  };

  return (
    <Dialog open={open} onOpenChange={(v) => (pending ? undefined : (setOpen(v), setError(null)))}>
      <DialogTrigger asChild>
        <Button variant={trigger.variant ?? 'secondary'} size={trigger.size ?? 'sm'} iconLeft={trigger.icon} disabled={trigger.disabled}>
          {trigger.label}
        </Button>
      </DialogTrigger>
      <DialogContent
        size={size}
        title={title}
        description={description}
        closeLabel={tc('close')}
        hideClose={pending}
        footer={
          <>
            <Button variant="secondary" disabled={pending} onClick={() => setOpen(false)}>
              {tc('cancel')}
            </Button>
            <Button type="submit" form={formId} variant={tone === 'danger' ? 'danger' : tone === 'ink' ? 'ink' : 'primary'} loading={pending}>
              {submitLabel}
            </Button>
          </>
        }
      >
        <form
          id={formId}
          className="flex flex-col gap-4"
          noValidate
          onSubmit={(e) => {
            e.preventDefault();
            submit(e.currentTarget);
          }}
        >
          {error ? <Alert tone="danger">{error}</Alert> : null}
          {children}
          {fields.map((f) => (
            <FieldControl key={f.name} f={f} />
          ))}
        </form>
      </DialogContent>
    </Dialog>
  );
}

function FieldControl({ f }: { f: FieldSpec }) {
  if (f.kind === 'checkbox') return <Checkbox name={f.name} label={f.label} description={f.helper} defaultChecked={f.defaultChecked} />;
  return (
    <Field label={f.label} helper={f.helper} required={f.required}>
      {f.kind === 'textarea' ? (
        <Textarea name={f.name} defaultValue={f.defaultValue} placeholder={f.placeholder} maxLength={f.maxLength} showCount={!!f.maxLength} rows={3} />
      ) : f.kind === 'select' ? (
        <Select name={f.name} options={f.options} defaultValue={f.defaultValue ?? (f.required ? f.options[0]?.value : undefined)} />
      ) : f.kind === 'file' ? (
        <input
          type="file"
          name={f.name}
          accept={f.accept}
          className="block w-full rounded-control border border-border bg-surface p-2.5 text-sm text-ink file:mr-3 file:rounded-[10px] file:border-0 file:bg-subtle file:px-3 file:py-2 file:text-sm file:font-semibold file:text-ink focus-ring"
        />
      ) : (
        <Input
          name={f.name}
          type={f.kind === 'datetime' ? 'datetime-local' : f.kind}
          defaultValue={f.defaultValue}
          placeholder={f.placeholder}
          min={f.min}
          max={f.max}
          step={f.step}
          maxLength={f.maxLength}
          prefix={f.prefix}
          suffix={f.suffix}
          inputMode={f.kind === 'number' ? 'decimal' : undefined}
        />
      )}
    </Field>
  );
}

/** Aksi satu klik (tanpa field) — tetap lewat konfirmasi kecuali `direct`. */
export function ActionButton({ label, icon, variant = 'secondary', success, action, direct }: { label: string; icon?: IconName; variant?: ButtonVariant; success: string; action: AdminAction; direct?: boolean }) {
  const errorText = useErrorText();
  const [pending, start] = useTransition();
  if (!direct) return <ActionDialog trigger={{ label, icon, variant }} title={label} submitLabel={label} success={success} action={action} />;
  return (
    <Button
      size="sm"
      variant={variant}
      iconLeft={icon}
      loading={pending}
      onClick={() =>
        start(async () => {
          const r = await action(new FormData());
          if (r.ok) toast.success(success);
          else toast.error(errorText(r.error));
        })
      }
    >
      {label}
    </Button>
  );
}
