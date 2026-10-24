'use client';

import { useId, useState, type ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Button, type ButtonVariant } from './button';
import { Dialog, DialogClose, DialogContent, DialogTrigger } from './dialog';
import { Icon, type IconName } from './icon';
import { Input } from './input';

export interface ConfirmDialogProps {
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  /** Element that opens the dialog (uncontrolled usage). */
  trigger?: ReactNode;
  title: ReactNode;
  /** Explain the consequence ("Views setelah ini ga dihitung."). */
  description?: ReactNode;
  /** Extra content (e.g. list of what will be deleted). */
  children?: ReactNode;
  confirmLabel?: string;
  cancelLabel?: string;
  /** `danger` (destructive, default), `ink` (money out), `primary`. */
  tone?: 'danger' | 'ink' | 'primary';
  icon?: IconName;
  /** Type-to-confirm (high risk, DS 12 §8): user must type this exact text, e.g. "HAPUS". */
  confirmText?: string;
  /** Label for the type-to-confirm input. Default `Ketik "<text>" untuk konfirmasi`. */
  confirmTextLabel?: ReactNode;
  /** Runs on confirm. If it returns a promise the button shows loading and the dialog closes on resolve. */
  onConfirm: () => void | Promise<unknown>;
  /** External loading flag (e.g. server action pending). */
  loading?: boolean;
}

const TONE: Record<NonNullable<ConfirmDialogProps['tone']>, { variant: ButtonVariant; icon: IconName; chip: string }> = {
  danger: { variant: 'danger', icon: 'warning', chip: 'bg-danger-bg text-danger-fg' },
  ink: { variant: 'ink', icon: 'payments', chip: 'bg-subtle text-ink' },
  primary: { variant: 'primary', icon: 'info', chip: 'bg-primary-soft text-primary-soft-fg' },
};

/** Confirmation for risky actions; optional "type to confirm". Cancel is left, confirm right ("kanan = maju"). */
export function ConfirmDialog({
  open: openProp,
  onOpenChange,
  trigger,
  title,
  description,
  children,
  confirmLabel = 'Ya, lanjutkan',
  cancelLabel = 'Batal',
  tone = 'danger',
  icon,
  confirmText,
  confirmTextLabel,
  onConfirm,
  loading: loadingProp,
}: ConfirmDialogProps) {
  const [internalOpen, setInternalOpen] = useState(false);
  const [typed, setTyped] = useState('');
  const [pending, setPending] = useState(false);
  const inputId = useId();
  const open = openProp ?? internalOpen;
  const setOpen = (v: boolean) => {
    if (!v) setTyped('');
    if (openProp === undefined) setInternalOpen(v);
    onOpenChange?.(v);
  };
  const t = TONE[tone];
  const loading = loadingProp || pending;
  const blocked = confirmText !== undefined && typed.trim() !== confirmText;

  const handleConfirm = async () => {
    if (blocked || loading) return;
    const r = onConfirm();
    if (r && typeof (r as Promise<unknown>).then === 'function') {
      setPending(true);
      try {
        await r;
        setOpen(false);
      } finally {
        setPending(false);
      }
    } else {
      setOpen(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={(v) => (loading ? undefined : setOpen(v))}>
      {trigger ? <DialogTrigger asChild>{trigger}</DialogTrigger> : null}
      <DialogContent
        size="sm"
        role="alertdialog"
        title={title}
        description={description}
        hideClose={loading}
        icon={
          <span className={cn('grid size-10 place-items-center rounded-full', t.chip)}>
            <Icon name={icon ?? t.icon} size={22} filled />
          </span>
        }
        onEscapeKeyDown={(e) => loading && e.preventDefault()}
        onPointerDownOutside={(e) => e.preventDefault()}
        footer={
          <>
            <DialogClose asChild>
              <Button variant="secondary" disabled={loading}>
                {cancelLabel}
              </Button>
            </DialogClose>
            <Button variant={t.variant} onClick={handleConfirm} loading={loading} disabled={blocked}>
              {confirmLabel}
            </Button>
          </>
        }
      >
        <form
          className="flex flex-col gap-4"
          onSubmit={(e) => {
            e.preventDefault();
            void handleConfirm();
          }}
        >
          {children}
          {confirmText !== undefined ? (
            <div className="flex flex-col gap-1.5">
              <label htmlFor={inputId} className="text-label text-ink">
                {confirmTextLabel ?? (
                  <>
                    Ketik <span className="rounded-tag bg-subtle px-1.5 py-0.5 font-mono text-[13px] font-bold">{confirmText}</span> untuk konfirmasi
                  </>
                )}
              </label>
              <Input
                id={inputId}
                value={typed}
                onChange={(e) => setTyped(e.target.value)}
                autoComplete="off"
                autoCapitalize="characters"
                spellCheck={false}
                success={!blocked}
              />
            </div>
          ) : null}
        </form>
      </DialogContent>
    </Dialog>
  );
}
