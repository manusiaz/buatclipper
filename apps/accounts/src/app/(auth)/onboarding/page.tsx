import type { Metadata } from 'next';
import { redirect } from 'next/navigation';
import { getTranslations } from 'next-intl/server';
import { hosts, safeNext } from '@clipper/auth';
import { coreServer, requireAccount } from '@clipper/auth/server';
import { Alert, AuthShell } from '@clipper/ui';
import { OnboardingForm } from '@/features/onboarding/onboarding-form';
import { initialUsername, latestLegal, roleOf } from '@/features/onboarding/rules';
import { identityDb } from '@/lib/identity';
import { ThemeSwitch } from '@/lib/theme-switch';
import { one, type SearchParams } from '@/lib/url';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('accounts.meta'))('onboarding') };
}

export default async function OnboardingPage({ searchParams }: { searchParams: SearchParams }) {
  const { claims } = await requireAccount();
  const sp = await searchParams;
  const next = one(sp.next);
  const role = roleOf(one(sp.role), next, hosts.brand);
  const [core, id, t] = await Promise.all([coreServer(), identityDb(), getTranslations('accounts.onboarding')]);
  const [profile, legal, membership] = await Promise.all([
    core.from('my_profile').select('username, display_name').maybeSingle(),
    id.from('legal_versions').select('kind, version, url, published_at').in('kind', [role === 'brand' ? 'tos_brand' : 'tos_clipper', 'privacy']),
    role === 'brand' ? core.from('org_members').select('org_id').eq('user_id', claims.sub).limit(1) : null,
  ]);
  if (legal.error) throw new Error(legal.error.message);

  // Anggota org yang diundang (B1.3 cabang J-B2) langsung ke brand, bukan ke buat organisasi.
  const fallback = role === 'brand' ? `${hosts.brand}/${membership?.data?.length ? '' : 'new'}` : `${hosts.app}/campaigns`;
  const dest = safeNext(next, fallback);
  if (claims.consent_ok?.[role]) redirect(dest);

  const docs = latestLegal(legal.data ?? []);
  const tos = docs[role === 'brand' ? 'tos_brand' : 'tos_clipper'];
  const privacy = docs.privacy;

  return (
    <AuthShell
      size="lg"
      title={role === 'brand' ? t('titleBrand') : t('titleClipper')}
      description={role === 'brand' ? t('subtitleBrand') : t('subtitleClipper')}
      topRight={<ThemeSwitch />}
      footer={claims.email ? t('signedInAs', { email: claims.email }) : undefined}
    >
      {tos && privacy ? (
        <OnboardingForm
          role={role}
          dest={dest}
          defaultUsername={initialUsername(profile.data?.username, claims.email)}
          defaultDisplayName={profile.data?.display_name ?? ''}
          tos={tos}
          privacy={privacy}
        />
      ) : (
        <Alert tone="danger" title={t('legalMissingTitle')}>
          {t('legalMissingBody')}
        </Alert>
      )}
    </AuthShell>
  );
}
