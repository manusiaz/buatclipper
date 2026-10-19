import { Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <div className="flex flex-col gap-4" aria-busy="true">
      <Skeleton className="h-24 w-full rounded-card" />
      <Skeleton className="h-36 w-full rounded-card" />
      <Skeleton className="h-44 w-full rounded-card" />
      <div className="grid grid-cols-2 gap-3">
        {[0, 1, 2, 3].map((i) => (
          <Skeleton key={i} className="h-24 rounded-card" />
        ))}
      </div>
    </div>
  );
}
