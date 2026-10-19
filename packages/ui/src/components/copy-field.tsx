'use client';

import { useEffect, useId, useRef, useState } from 'react';
import { cn } from '../lib/cn';
import { Icon } from './icon';

export interface CopyFieldProps {
  value: string;
  /** Visible label above the field. */
  label?: string;
  /** Button text. Default "Salin". */
  copyLabel?: string;
  copiedLabel?: string;
  /** Monospace + letter-spacing (codes like "CLIP-7Q2X", DS type/mono). */
  mono?: boolean;
  /** Called after a successful copy (e.g. toast.success("Kode referral disalin")). */
  onCopied?: (value: string) => void;
  className?: string;
}

async function writeClipboard(text: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.setAttribute('readonly', '');
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  document.execCommand('copy');
  ta.remove();
}

/** Read-only value + copy button (referral code, link, invoice no.). Announces "Disalin" politely. */
export function CopyField({ value, label, copyLabel = 'Salin', copiedLabel = 'Disalin', mono, onCopied, className }: CopyFieldProps) {
  const [copied, setCopied] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const id = useId();
  useEffect(() => () => {
    if (timer.current) clearTimeout(timer.current);
  }, []);
  const copy = async () => {
    try {
      await writeClipboard(value);
      setCopied(true);
      onCopied?.(value);
      if (timer.current) clearTimeout(timer.current);
      timer.current = setTimeout(() => setCopied(false), 2000);
    } catch {
      setCopied(false);
    }
  };
  return (
    <div className={cn('flex flex-col gap-1.5', className)}>
      {label ? (
        <label htmlFor={id} className="text-label text-ink">
          {label}
        </label>
      ) : null}
      <div className="flex h-12 items-center gap-2 rounded-control border-[1.5px] border-border-strong bg-surface-2 pr-1.5 pl-3.5">
        <input
          id={id}
          readOnly
          value={value}
          aria-label={label ? undefined : value}
          onFocus={(e) => e.currentTarget.select()}
          className={cn('min-w-0 flex-1 bg-transparent text-base text-ink outline-none', mono && 'font-mono text-sm font-semibold tracking-[0.06em]')}
        />
        <button
          type="button"
          onClick={copy}
          className={cn(
            'inline-flex h-9 shrink-0 items-center gap-1.5 rounded-[10px] px-3 text-sm font-bold transition-colors duration-120 focus-ring',
            copied ? 'bg-success-bg text-success-fg' : 'bg-primary-soft text-primary-soft-fg hover:bg-primary-soft-hover',
          )}
        >
          <Icon name={copied ? 'check' : 'content_copy'} size={18} />
          {copied ? copiedLabel : copyLabel}
        </button>
        <span className="sr-only" aria-live="polite">
          {copied ? copiedLabel : ''}
        </span>
      </div>
    </div>
  );
}
