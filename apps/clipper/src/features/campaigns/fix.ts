// State terblokir harus jadi aksi berikutnya (Catatan UX KitaClip): alasan not_eligible → tombol perbaiki.
import { hosts, kycUrl, onboardingUrl } from '@clipper/auth';

export type FixKey = 'connect' | 'kyc' | 'onboarding' | 'trust';

/** reason = cta_reason list_campaigns (mis. "need_social_account:tiktok") atau kode error claim tanpa awalan not_eligible:. */
export function fixFor(reason: string | null | undefined, campaignId: string): { key: FixKey; href: string } | null {
  const back = `/campaigns/${campaignId}`;
  const r = (reason ?? '').replace(/^not_eligible:/, '');
  if (r.startsWith('need_social_account') || r === 'min_followers' || r === 'min_account_age') {
    return { key: 'connect', href: `/social?next=${encodeURIComponent(back)}` };
  }
  if (r === 'kyc_required') return { key: 'kyc', href: kycUrl(`${hosts.app}${back}`) };
  if (r === 'profile_missing') return { key: 'onboarding', href: onboardingUrl('clipper', `${hosts.app}${back}`) };
  if (r === 'min_trust_score') return { key: 'trust', href: '/profile' };
  return null;
}
