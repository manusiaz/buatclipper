// /campaign/[id] (?submit=1 buka sheet Submit, ?url= link dari share sheet) — isi di src/screens/campaign-detail.tsx.
import { useLocalSearchParams } from 'expo-router';
import { CampaignDetail } from '@/screens/campaign-detail';

export default function DetailRoute() {
  const { id, submit, url } = useLocalSearchParams<{ id: string; submit?: string; url?: string }>();
  return <CampaignDetail id={id} submit={submit === '1'} sharedUrl={url} />;
}
