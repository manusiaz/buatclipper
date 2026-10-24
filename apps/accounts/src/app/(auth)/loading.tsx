import { AuthShell, Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <AuthShell>
      <div aria-busy="true" className="flex flex-col gap-5">
        <Skeleton shape="text" className="mx-auto h-7 w-48" />
        <Skeleton shape="text" className="mx-auto w-64 max-w-full" />
        <Skeleton className="h-11 w-full" />
        <Skeleton className="h-11 w-full" />
        <Skeleton className="h-12 w-full" />
      </div>
    </AuthShell>
  );
}
