import { Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <div className="flex flex-col gap-4" aria-busy="true">
      <Skeleton shape="text" className="h-7 w-36" />
      <Skeleton shape="text" className="h-5 w-24" />
      {[0, 1, 2].map((i) => (
        <Skeleton key={i} className="h-40 w-full rounded-card" />
      ))}
    </div>
  );
}
