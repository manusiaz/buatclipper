import { Card, Skeleton } from '@clipper/ui';

/** Skeleton loading.tsx: judul + kartu statistik (opsional) + tabel. */
export function PageSkeleton({ stats = 0, rows = 6 }: { stats?: number; rows?: number }) {
  return (
    <div className="flex flex-col gap-5" aria-busy="true">
      <div className="flex flex-col gap-2 pt-2 pb-1">
        <Skeleton shape="text" className="h-8 w-56" />
        <Skeleton shape="text" className="h-4 w-80 max-w-full" />
      </div>
      {stats > 0 ? (
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          {Array.from({ length: stats }, (_, i) => (
            <Skeleton key={i} className="h-32 rounded-card" />
          ))}
        </div>
      ) : null}
      <Card padding="none" className="flex flex-col divide-y divide-border">
        {Array.from({ length: rows }, (_, i) => (
          <div key={i} className="flex items-center gap-4 px-4 py-4">
            <Skeleton shape="circle" className="size-9" />
            <div className="flex flex-1 flex-col gap-2">
              <Skeleton shape="text" className="h-4 w-1/2" />
              <Skeleton shape="text" className="h-3 w-1/3" />
            </div>
            <Skeleton className="h-8 w-24 rounded-[10px]" />
          </div>
        ))}
      </Card>
    </div>
  );
}
