import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { isAdmin } from '@clipper/auth';
import { brandServer, getAuth } from '@clipper/auth/server';
import { Alert, AuthShell, Button, Icon } from '@clipper/ui';
import { AcceptInvite } from '@/features/invite/accept-invite';
import { switchAccount } from '@/features/invite/actions';
import { errorKeys } from '@/lib/errors';
import { ThemeSwitch } from '@/lib/theme-switch';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('accounts.meta'))('invite') };
}

/** Publik (proxy membuka /invite). api.invite_preview: token = kapabilitas, jadi nama org & peran tampil sebelum login. */
export default async function InvitePage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const [{ claims }, t, tAll, brand] = await Promise.all([getAuth('sso'), getTranslations('accounts.invite'), getTranslations(), brandServer()]);
  const signedIn = !!claims && !isAdmin(claims);
  const here = `/invite/${encodeURIComponent(token)}`;
  const { data: preview } = await brand.rpc('invite_preview', { p_token: token }).maybeSingle();
  // Sudah dipakai tapi user login: accept_org_invite idempoten untuk anggota org, jadi biarkan AcceptInvite yang memutuskan.
  const dead = !preview ? 'not_found:invite' : preview.expired ? 'invite_expired' : preview.used && !signedIn ? 'invite_used' : null;
  const deadText = dead ? tAll(errorKeys(dead).keys.find((k) => tAll.has(k)) ?? 'errors.generic') : null;

  return (
    <AuthShell
      title={t('title')}
      description={preview ? t.rich('bodyOrg', { org: preview.org_name, role: t(`roles.${preview.role}`), b: (c) => <strong>{c}</strong> }) : t('body')}
      topRight={<ThemeSwitch />}
    >
      <div className="flex flex-col gap-5">
        <div className="flex items-start gap-3 rounded-card-sm bg-primary-soft p-4 text-primary-soft-fg">
          <Icon name="storefront" size={22} filled className="mt-0.5 shrink-0" />
          <p className="text-body-s">{t('what')}</p>
        </div>
        {deadText ? (
          <Alert tone="danger" title={deadText}>
            {t('askNewLink')}
          </Alert>
        ) : signedIn ? (
          <>
            <AcceptInvite token={token} />
            <form action={switchAccount.bind(null, token)} className="flex flex-wrap items-center justify-center gap-x-1 text-body-s text-muted">
              <span className="min-w-0 max-w-full truncate">{t('signedInAs', { email: claims.email ?? '' })}</span>
              <Button type="submit" variant="link" size="sm">
                {t('notYou')}
              </Button>
            </form>
          </>
        ) : (
          <Button href={`/login?next=${encodeURIComponent(here)}`} linkAs={Link} size="lg" fullWidth iconLeft="login">
            {t('login')}
          </Button>
        )}
      </div>
    </AuthShell>
  );
}
