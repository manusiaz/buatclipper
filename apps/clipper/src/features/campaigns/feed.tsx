'use client';

import { useCallback, useEffect, useRef, useState, useTransition } from 'react';
import Link from 'next/link';
import { useLocale, useTranslations } from 'next-intl';
import { Alert, Button, CampaignCard, StatusBadge } from '@clipper/ui';
import { loadMoreCampaigns } from './actions';
import type { CampaignCardData } from './cards';
import type { CampaignFilters } from './filters';

export function CampaignFeed({ initial, next, filters }: { initial: CampaignCardData[]; next: string | null; filters: CampaignFilters }) {
  const t = useTranslations('clipper.campaigns');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const [items, setItems] = useState(initial);
  const [cursor, setCursor] = useState(next);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const sentinel = useRef<HTMLDivElement>(null);

  const load = useCallback(() => {
    if (!cursor || pending) return;
    start(async () => {
      const r = await loadMoreCampaigns(filters, cursor);
      if (!r.ok) {
        setError(r.message);
        return;
      }
      setError(null);
      setItems((prev) => {
        const seen = new Set(prev.map((c) => c.id));
        return [...prev, ...r.items.filter((c) => !seen.has(c.id))];
      });
      setCursor(r.next);
    });
  }, [cursor, pending, filters]);

  useEffect(() => {
    const el = sentinel.current;
    if (!el || !cursor || error) return;
    const io = new IntersectionObserver((entries) => entries.some((e) => e.isIntersecting) && load(), { rootMargin: '600px 0px' });
    io.observe(el);
    return () => io.disconnect();
  }, [cursor, error, load]);

  return (
    <div className="flex flex-col gap-4">
      <ul className="flex flex-col gap-4" aria-label={t('listLabel')}>
        {items.map((c) => (
          <li key={c.id}>
            <CampaignCard
              href={`/campaigns/${c.id}`}
              linkAs={Link}
              locale={locale}
              title={c.title}
              brand={c.brand}
              coverSrc={c.coverSrc}
              category={c.category}
              categoryIcon={c.categoryIcon}
              platforms={c.platforms}
              rates={c.rates}
              pinned={c.pinned}
              isNew={c.isNew}
              status={c.status !== 'live' ? <StatusBadge kind="campaign" status={c.status} label={c.statusLabel} size="sm" /> : undefined}
              deadline={c.deadline}
              remainingViews={c.remainingViews}
              budgetUsedRatio={c.budgetUsedRatio}
              ctaState={c.ctaState}
              ctaHref={c.ctaHref}
              ctaReason={c.ctaReason}
              ctaAction={c.ctaAction}
              claimExpiresAt={c.claimExpiresAt}
            />
          </li>
        ))}
      </ul>
      {error ? (
        <Alert tone="danger" action={{ label: t('retry'), onClick: load }}>
          {error}
        </Alert>
      ) : null}
      {cursor ? (
        <div ref={sentinel} className="flex justify-center">
          <Button variant="secondary" loading={pending} onClick={load} loadingText={t('loadingMore')}>
            {t('loadMore')}
          </Button>
        </div>
      ) : items.length > 3 ? (
        <p className="py-2 text-center text-caption text-muted">{t('end')}</p>
      ) : null}
    </div>
  );
}
