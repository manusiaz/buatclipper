import { PageSkeleton } from '@/features/shared/page-skeleton';

export default function Loading() {
  return <PageSkeleton stats={0} rows={6} />;
}
