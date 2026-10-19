import { Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <div className="flex flex-col gap-5" aria-busy>
      <div className="flex flex-col gap-2 pt-2">
        <Skeleton shape="text" className="h-9 w-1/2 max-w-[360px]" />
        <Skeleton shape="text" className="w-2/3 max-w-[520px]" />
      </div>
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        {Array.from({ length: 4 }, (_, i) => <Skeleton key={i} className="h-28" />)}
      </div>
      <Skeleton className="h-72" />
    </div>
  );
}
