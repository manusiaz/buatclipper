// Aksi "perbaiki" untuk state terblokir (Catatan UX KitaClip; sama dengan features/campaigns/fix.ts web):
// connect → Sosmed, kyc / onboarding → halaman akun (browser, sesi dibawa), trust → Profil.
import type { useRouter } from 'expo-router';
import type { FixKey } from '@clipper/clipper-lib/pure';
import { openWeb } from './web';

export function runFix(fix: FixKey | null, router: ReturnType<typeof useRouter>, campaignId?: string) {
  const back = campaignId ? `/campaign/${campaignId}` : '/';
  if (fix === 'connect') return router.push({ pathname: '/social', params: { next: back } });
  if (fix === 'kyc') return void openWeb('accounts', '/kyc');
  if (fix === 'onboarding') return void openWeb('accounts', '/onboarding');
  if (fix === 'trust') return router.push('/profile');
}
