// State terblokir harus jadi aksi berikutnya (Catatan UX KitaClip): alasan not_eligible → tombol perbaiki.
import { hosts, kycUrl, onboardingUrl } from '@clipper/auth';
import { fixKey, type FixKey } from '@clipper/clipper-lib/pure';

export type { FixKey };

/** reason = cta_reason list_campaigns (mis. "need_social_account:tiktok") atau kode error claim tanpa awalan not_eligible:. */
export function fixFor(reason: string | null | undefined, campaignId: string): { key: FixKey; href: string } | null {
  const back = `/campaigns/${campaignId}`;
  const key = fixKey(reason);
  if (key === 'connect') return { key, href: `/social?next=${encodeURIComponent(back)}` };
  if (key === 'kyc') return { key, href: kycUrl(`${hosts.app}${back}`) };
  if (key === 'onboarding') return { key, href: onboardingUrl('clipper', `${hosts.app}${back}`) };
  if (key === 'trust') return { key, href: '/profile' };
  return null;
}
