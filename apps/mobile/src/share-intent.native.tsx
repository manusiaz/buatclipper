// Share sheet Android/iOS (expo-share-intent): link video dari TikTok/IG/YouTube → /share (pilih claim → submit).
import { useRouter } from 'expo-router';
import { useEffect } from 'react';
import { useShareIntent } from 'expo-share-intent';
import { sharedUrl } from '@clipper/clipper-lib/pure';

export function ShareIntentGate() {
  const { hasShareIntent, shareIntent, resetShareIntent } = useShareIntent();
  const router = useRouter();
  useEffect(() => {
    if (!hasShareIntent) return;
    const url = sharedUrl({ url: shareIntent.webUrl ?? undefined, text: shareIntent.text ?? undefined });
    router.push({ pathname: '/share', params: url ? { url } : {} });
    resetShareIntent();
  }, [hasShareIntent, shareIntent, resetShareIntent, router]);
  return null;
}
