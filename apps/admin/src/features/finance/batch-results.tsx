'use client';

import { useState, useTransition } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { Alert, Button, formatIDR, Input, RadioGroup, Table, TBody, TD, TH, THead, TR, toast, type UiLocale } from '@clipper/ui';
import { useErrorText } from '@/features/shared/use-error-text';
import { markBatch } from './actions';

export interface ProcessingPayout {
  id: string;
  username: string;
  net: number;
}

/** A3.4: tandai paid/failed per payout yang masuk CSV (+ nomor referensi bank). */
export function BatchResults({ batchId, payouts }: { batchId: string; payouts: ProcessingPayout[] }) {
  const t = useTranslations('admin.finance');
  const loc = useLocale() as UiLocale;
  const errorText = useErrorText();
  const [state, setState] = useState<Record<string, { status: 'paid' | 'failed'; bank_ref: string; reason: string }>>(() =>
    Object.fromEntries(payouts.map((p) => [p.id, { status: 'paid', bank_ref: '', reason: '' }])),
  );
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const failed = Object.values(state).filter((s) => s.status === 'failed').length;

  const submit = () =>
    start(async () => {
      setError(null);
      const r = await markBatch(batchId, payouts.map((p) => ({ payout_id: p.id, ...state[p.id]! })));
      if (r.ok) toast.success(t('markedDone'));
      else setError(errorText(r.error));
    });

  return (
    <div className="flex flex-col gap-3">
      {error ? <Alert tone="danger">{error}</Alert> : null}
      <Table dense>
        <THead>
          <TR>
            <TH>{t('payout')}</TH>
            <TH align="right">{t('net')}</TH>
            <TH>{t('result')}</TH>
            <TH>{t('bankRef')}</TH>
          </TR>
        </THead>
        <TBody>
          {payouts.map((p) => (
            <TR key={p.id}>
              <TD>
                <span className="font-semibold text-ink">@{p.username}</span>
                <code className="block font-mono text-[11px] text-muted">{p.id}</code>
              </TD>
              <TD numeric>{formatIDR(p.net, { locale: loc })}</TD>
              <TD>
                <RadioGroup
                  name={`r-${p.id}`}
                  legend={t('result')}
                  orientation="horizontal"
                  value={state[p.id]!.status}
                  onValueChange={(v) => setState((s) => ({ ...s, [p.id]: { ...s[p.id]!, status: v as 'paid' | 'failed' } }))}
                  options={[
                    { value: 'paid', label: t('paid') },
                    { value: 'failed', label: t('failed') },
                  ]}
                />
              </TD>
              <TD>
                <div className="flex flex-col gap-2">
                  <Input
                    inputSize="sm"
                    aria-label={t('bankRef')}
                    required={state[p.id]!.status === 'paid'}
                    value={state[p.id]!.bank_ref}
                    maxLength={100}
                    onChange={(e) => setState((s) => ({ ...s, [p.id]: { ...s[p.id]!, bank_ref: e.target.value } }))}
                  />
                  {state[p.id]!.status === 'failed' ? (
                    <Input
                      inputSize="sm"
                      aria-label={t('failReason')}
                      placeholder={t('failReason')}
                      value={state[p.id]!.reason}
                      maxLength={500}
                      onChange={(e) => setState((s) => ({ ...s, [p.id]: { ...s[p.id]!, reason: e.target.value } }))}
                    />
                  ) : null}
                </div>
              </TD>
            </TR>
          ))}
        </TBody>
      </Table>
      <div className="flex flex-wrap items-center gap-3">
        <Button variant="ink" iconLeft="check_circle" loading={pending} onClick={submit}>
          {t('markSubmit', { paid: payouts.length - failed, failed })}
        </Button>
        <span className="text-caption text-muted">{t('markHint')}</span>
      </div>
    </div>
  );
}
