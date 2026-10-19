import { Button, Field, Input, Select } from '@clipper/ui';

export type Filter =
  | { kind: 'select'; name: string; label: string; value: string; options: { value: string; label: string }[]; placeholder?: string }
  | { kind: 'text' | 'date'; name: string; label: string; value: string; placeholder?: string };

/** Filter GET (query string) untuk antrean yang dibaca di server. */
export function FilterBar({ filters, submitLabel, resetHref, resetLabel, hidden = {} }: {
  filters: Filter[];
  submitLabel: string;
  resetHref: string;
  resetLabel: string;
  hidden?: Record<string, string>;
}) {
  return (
    <form method="get" className="mb-5 flex flex-col gap-3 sm:flex-row sm:flex-wrap sm:items-end">
      {Object.entries(hidden).map(([k, v]) => (
        <input key={k} type="hidden" name={k} value={v} />
      ))}
      {filters.map((f) => (
        <Field key={f.name} label={f.label} className="sm:w-56">
          {f.kind === 'select' ? (
            <Select name={f.name} inputSize="sm" defaultValue={f.value || undefined} placeholder={f.placeholder} options={f.options} />
          ) : (
            <Input name={f.name} type={f.kind} inputSize="sm" defaultValue={f.value} placeholder={f.placeholder} />
          )}
        </Field>
      ))}
      <div className="flex gap-2">
        <Button type="submit" size="md" variant="secondary" iconLeft="filter_list">
          {submitLabel}
        </Button>
        <Button href={resetHref} size="md" variant="ghost">
          {resetLabel}
        </Button>
      </div>
    </form>
  );
}
