import { Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <div className="flex flex-col gap-4" aria-busy="true">
      <Skeleton shape="text" className="h-7 w-40" />
      <Skeleton shape="text" className="w-3/4" />
      {[0, 1, 2].map((i) => (
        <Skeleton key={i} className="h-24 w-full rounded-card" />
      ))}
    </div>
  );
}
