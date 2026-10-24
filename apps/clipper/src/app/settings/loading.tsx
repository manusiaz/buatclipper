import { Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <div className="flex flex-col gap-4" aria-busy="true">
      <Skeleton className="h-48 w-full rounded-card" />
      <Skeleton className="h-56 w-full rounded-card" />
      <Skeleton className="h-36 w-full rounded-card" />
    </div>
  );
}
