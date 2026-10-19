import { cn } from '@clipper/ui';

const show = (v: unknown): string => (typeof v === 'string' ? v : JSON.stringify(v));

/** Payload jsonb (alert, fraud flag, audit) sebagai daftar kunci: nilai. Non-object → JSON satu baris. */
export function JsonView({ value, max = 8, className }: { value: unknown; max?: number; className?: string }) {
  if (value == null) return <span className="text-muted">—</span>;
  if (typeof value !== 'object' || Array.isArray(value)) {
    return <code className={cn('font-mono text-caption break-all text-text-2', className)}>{show(value)}</code>;
  }
  const entries = Object.entries(value as Record<string, unknown>);
  if (entries.length === 0) return <span className="text-muted">—</span>;
  return (
    <dl className={cn('grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 text-caption', className)}>
      {entries.slice(0, max).map(([k, v]) => (
        <div key={k} className="contents">
          <dt className="font-semibold text-muted">{k}</dt>
          <dd className="min-w-0 font-mono break-all text-text-2">{show(v)}</dd>
        </div>
      ))}
      {entries.length > max ? <dd className="col-span-2 text-muted">+{entries.length - max}</dd> : null}
    </dl>
  );
}
