import { Container, Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <Container size="md" className="flex flex-col gap-6 py-8 md:py-12" aria-busy="true">
      <Skeleton shape="text" className="h-4 w-32" />
      <Skeleton shape="text" className="h-10 w-3/4" />
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        {Array.from({ length: 4 }, (_, i) => (
          <Skeleton key={i} className="h-28 rounded-card" />
        ))}
      </div>
      <div className="grid gap-4 md:grid-cols-2">
        <Skeleton className="h-56 rounded-card" />
        <Skeleton className="h-56 rounded-card" />
      </div>
    </Container>
  );
}
