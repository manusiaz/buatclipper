import { Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <div className="flex flex-col gap-4" aria-busy="true">
      <Skeleton className="aspect-[16/9] w-full rounded-card" />
      <Skeleton shape="text" className="w-24" />
      <Skeleton shape="text" className="h-6 w-4/5" />
      <Skeleton className="h-32 w-full rounded-card" />
      <Skeleton className="h-40 w-full rounded-card" />
      <Skeleton className="h-56 w-full rounded-card" />
    </div>
  );
}
