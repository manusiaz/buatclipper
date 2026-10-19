import { Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <div className="flex flex-col gap-4" aria-busy="true">
      <Skeleton shape="text" className="w-3/4" />
      <Skeleton className="h-11 w-full rounded-control" />
      <Skeleton className="h-96 w-full rounded-card" />
    </div>
  );
}
