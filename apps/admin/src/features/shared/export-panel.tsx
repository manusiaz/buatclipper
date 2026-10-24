'use client';

// Hasil export pii-export: link unduh 15 menit + baris yang ditahan/dilewati beserta alasannya (A3.3, A5.1, PPh 21).
import { useState, useTransition, type ReactNode } from 'react';
import { useTranslations } from 'next-intl';
import { Alert, Button, Card, Countdown, type IconName } from '@clipper/ui';
import type { ActionResult } from '@/lib/action';
import { useErrorText } from './use-error-text';

export interface ExportResult {
  url: string;
  expires_in: number;
  rows: number;
  items: { id: string; reason: string }[];
}

export function ExportPanel({ label, icon = 'download', action, itemsTitle, form }: {
  label: string;
  icon?: IconName;
  action: (fd: FormData) => Promise<ActionResult<ExportResult>>;
  itemsTitle: string;
  /** Field tambahan (mis. rentang tanggal PPh 21) dirender di dalam form. */
  form?: ReactNode;
}) {
  const t = useTranslations('admin.export');
  const errorText = useErrorText();
  const [pending, start] = useTransition();
  const [res, setRes] = useState<(ExportResult & { until: number }) | null>(null);
  const [error, setError] = useState<string | null>(null);

  return (
    <div className="flex flex-col gap-3">
      <form
        className="flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-end"
        onSubmit={(e) => {
          e.preventDefault();
          const fd = new FormData(e.currentTarget);
          start(async () => {
            setError(null);
            const r = await action(fd);
            if (!r.ok || !r.data) return setError(errorText(r.ok ? 'generic' : r.error));
            setRes({ ...r.data, until: Date.now() + r.data.expires_in * 1000 });
          });
        }}
      >
        {form}
        <Button type="submit" variant="ink" iconLeft={icon} loading={pending}>
          {label}
        </Button>
      </form>
      {error ? <Alert tone="danger">{error}</Alert> : null}
      {res ? (
        <Card variant="tint" padding="md" className="flex flex-col gap-3">
          <div className="flex flex-wrap items-center gap-3">
            <Button href={res.url} external variant="primary" iconLeft="download">
              {t('download', { rows: res.rows })}
            </Button>
            <span className="text-body-s text-muted">
              {t('expires')} <Countdown target={new Date(res.until)} showSeconds expiredLabel={t('expired')} />
            </span>
          </div>
          {res.items.length > 0 ? (
            <div className="flex flex-col gap-1.5">
              <p className="text-label text-ink">{itemsTitle} ({res.items.length})</p>
              <ul className="flex max-h-60 flex-col gap-1 overflow-y-auto text-body-s">
                {res.items.map((i) => (
                  <li key={i.id} className="flex flex-wrap gap-x-2">
                    <code className="font-mono text-caption text-muted">{i.id}</code>
                    <span className="text-ink">{t.has(`reasons.${i.reason}`) ? t(`reasons.${i.reason}`) : i.reason}</span>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
        </Card>
      ) : null}
    </div>
  );
}
