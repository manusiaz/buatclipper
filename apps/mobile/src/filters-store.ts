// Filter daftar campaign (status/kategori/urutan/platform/cari) — dibagi layar Campaign dan sheet Filter.
import { useSyncExternalStore } from 'react';
import type { CampaignFilters } from '@clipper/clipper-lib/filters';

export const DEFAULT_FILTERS: CampaignFilters = { q: '', platform: '', category: '', status: 'active', sort: 'newest' };

let state: CampaignFilters = DEFAULT_FILTERS;
const subs = new Set<() => void>();

export function setFilters(next: Partial<CampaignFilters>) {
  state = { ...state, ...next };
  subs.forEach((f) => f());
}

export function useFilters(): CampaignFilters {
  return useSyncExternalStore(
    (f) => (subs.add(f), () => void subs.delete(f)),
    () => state,
    () => state,
  );
}
