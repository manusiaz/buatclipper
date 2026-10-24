import { redirect } from 'next/navigation';

export default async function OrgHome({ params }: { params: Promise<{ org: string }> }) {
  redirect(`/${(await params).org}/campaigns`);
}
