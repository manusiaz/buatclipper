'use client';

import { useEffect, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useTranslations } from 'next-intl';
import { Button, SearchInput, Select, Spinner, platformLabels, type Platform } from '@clipper/ui';
import { filtersToQuery, SORTS, STATUSES, type CampaignFilters } from './filters';

const ANY = 'any';

export function FilterBar({
  filters,
  platforms,
  categories,
}: {
  filters: CampaignFilters;
  platforms: Platform[];
  categories: { id: string; name: string }[];
}) {
  const t = useTranslations('clipper.campaigns');
  const router = useRouter();
  const [pending, start] = useTransition();
  const [q, setQ] = useState(filters.q);
  const first = useRef(true);

  const apply = (patch: Partial<CampaignFilters>) =>
    start(() => router.replace(`/campaigns${filtersToQuery({ ...filters, ...patch })}`, { scroll: false }));

  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    const id = setTimeout(() => {
      if (q.trim() !== filters.q) apply({ q: q.trim() });
    }, 350);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q]);

  const changed = filters.platform || filters.category || filters.status !== 'active' || filters.sort !== 'newest' || filters.q;

  return (
    <div className="flex flex-col gap-2.5" role="search" aria-busy={pending}>
      <SearchInput
        value={q}
        onValueChange={setQ}
        onClear={() => {
          setQ('');
          apply({ q: '' });
        }}
        placeholder={t('searchPlaceholder')}
        aria-label={t('search')}
        clearLabel={t('clearSearch')}
        enterKeyHint="search"
        trailing={pending ? <Spinner size={16} /> : undefined}
      />
      <div className="no-scrollbar -mx-4 flex gap-2 overflow-x-auto px-4 pb-1">
        <Select
          inputSize="sm"
          className="w-auto min-w-36 shrink-0"
          aria-label={t('platform')}
          value={filters.platform || ANY}
          onValueChange={(v) => apply({ platform: v === ANY ? '' : v })}
          options={[{ value: ANY, label: t('allPlatforms') }, ...platforms.map((p) => ({ value: p, label: platformLabels[p] }))]}
        />
        <Select
          inputSize="sm"
          className="w-auto min-w-36 shrink-0"
          aria-label={t('status')}
          value={filters.status}
          onValueChange={(v) => apply({ status: v as CampaignFilters['status'] })}
          options={STATUSES.map((s) => ({ value: s, label: t(`statusFilter.${s}`) }))}
        />
        <Select
          inputSize="sm"
          className="w-auto min-w-36 shrink-0"
          aria-label={t('category')}
          value={filters.category || ANY}
          onValueChange={(v) => apply({ category: v === ANY ? '' : v })}
          options={[{ value: ANY, label: t('allCategories') }, ...categories.map((c) => ({ value: c.id, label: c.name }))]}
        />
        <Select
          inputSize="sm"
          className="w-auto min-w-40 shrink-0"
          aria-label={t('sort')}
          iconLeft="sort"
          value={filters.sort}
          onValueChange={(v) => apply({ sort: v as CampaignFilters['sort'] })}
          options={SORTS.map((s) => ({ value: s, label: t(`sortBy.${s}`) }))}
        />
        {changed ? (
          <Button
            size="sm"
            variant="ghost"
            className="shrink-0"
            iconLeft="close"
            onClick={() => {
              setQ('');
              start(() => router.replace('/campaigns', { scroll: false }));
            }}
          >
            {t('reset')}
          </Button>
        ) : null}
      </div>
    </div>
  );
}
