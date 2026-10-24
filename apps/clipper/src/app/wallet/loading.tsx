import { Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <div className="flex flex-col gap-4" aria-busy="true">
      <Skeleton shape="text" className="h-7 w-28" />
      <Skeleton className="h-11 w-full rounded-control" />
      <Skeleton className="h-28 w-full rounded-card" />
      <div className="grid grid-cols-2 gap-3">
        <Skeleton className="h-24 rounded-card" />
        <Skeleton className="h-24 rounded-card" />
      </div>
      <Skeleton className="h-12 w-full rounded-control" />
      <Skeleton className="h-64 w-full rounded-card" />
    </div>
  );
}
