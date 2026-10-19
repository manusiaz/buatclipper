import { CampaignCardSkeleton, Skeleton } from '@clipper/ui';

export default function Loading() {
  return (
    <div className="flex flex-col gap-4" aria-busy="true">
      <Skeleton shape="text" className="h-7 w-32" />
      <Skeleton className="h-11 w-full rounded-control" />
      <div className="flex gap-2">
        <Skeleton className="h-9 w-32 rounded-control" />
        <Skeleton className="h-9 w-32 rounded-control" />
        <Skeleton className="h-9 w-32 rounded-control" />
      </div>
      <CampaignCardSkeleton />
      <CampaignCardSkeleton />
    </div>
  );
}
