import { Container, Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <Container className="pt-4 pb-16 md:pt-8" aria-busy="true">
      <Skeleton shape="text" className="mb-4 h-5 w-40" />
      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="flex flex-col gap-5">
          <Skeleton className="aspect-[16/9] w-full rounded-media" />
          <Skeleton shape="text" className="h-6 w-48" />
          <Skeleton shape="text" className="h-10 w-4/5" />
          <Skeleton className="h-56 w-full rounded-card" />
        </div>
        <Skeleton className="h-[420px] w-full rounded-card" />
      </div>
    </Container>
  );
}
