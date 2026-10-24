import { Card, Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <div aria-busy="true" className="flex flex-col gap-5">
      <div className="flex flex-col gap-2 pt-2 pb-3">
        <Skeleton shape="text" className="h-8 w-56" />
        <Skeleton shape="text" className="w-80 max-w-full" />
      </div>
      <div className="grid gap-4 md:grid-cols-2">
        {[0, 1, 2, 3].map((i) => (
          <Card key={i} className="flex flex-col gap-3">
            <Skeleton shape="circle" className="size-10" />
            <Skeleton shape="text" className="w-32" />
            <Skeleton shape="text" className="w-48" />
          </Card>
        ))}
      </div>
    </div>
  );
}
