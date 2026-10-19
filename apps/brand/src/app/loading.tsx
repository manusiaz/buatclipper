import { Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <div className="mx-auto flex max-w-[960px] flex-col gap-4 px-5 py-10" aria-busy>
      <Skeleton shape="text" className="h-9 w-1/2" />
      <Skeleton shape="text" className="w-2/3" />
      <div className="grid gap-3 sm:grid-cols-2">
        <Skeleton className="h-24" />
        <Skeleton className="h-24" />
      </div>
    </div>
  );
}
