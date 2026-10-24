import { PageSkeleton } from '@/features/shared/page-skeleton';

export default function Loading() {
  return <PageSkeleton stats={4} rows={6} />;
}
