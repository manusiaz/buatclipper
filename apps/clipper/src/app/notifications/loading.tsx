import { Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <div className="flex flex-col gap-3" aria-busy="true">
      <Skeleton shape="text" className="w-32" />
      {[0, 1, 2, 3, 4].map((i) => (
        <div key={i} className="flex gap-3">
          <Skeleton shape="circle" className="size-10 shrink-0" />
          <div className="flex flex-1 flex-col gap-2">
            <Skeleton shape="text" className="w-3/4" />
            <Skeleton shape="text" className="w-1/2" />
          </div>
        </div>
      ))}
    </div>
  );
}
