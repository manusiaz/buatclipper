import type { Metadata } from 'next';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { isAdmin } from '@clipper/auth';
import { getAuth } from '@clipper/auth/server';
import { AuthShell, Button, Icon } from '@clipper/ui';
import { AcceptInvite } from '@/features/invite/accept-invite';
import { switchAccount } from '@/features/invite/actions';
import { ThemeSwitch } from '@/lib/theme-switch';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('accounts.meta'))('invite') };
}

/** Publik (proxy membuka /invite). Core tidak membuka undangan ke anon, jadi nama org belum bisa ditampilkan. */
export default async function InvitePage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const [{ claims }, t] = await Promise.all([getAuth('sso'), getTranslations('accounts.invite')]);
  const signedIn = !!claims && !isAdmin(claims);
  const here = `/invite/${encodeURIComponent(token)}`;

  return (
    <AuthShell title={t('title')} description={t('body')} topRight={<ThemeSwitch />}>
      <div className="flex flex-col gap-5">
        <div className="flex items-start gap-3 rounded-card-sm bg-primary-soft p-4 text-primary-soft-fg">
          <Icon name="storefront" size={22} filled className="mt-0.5 shrink-0" />
          <p className="text-body-s">{t('what')}</p>
        </div>
        {signedIn ? (
          <>
            <AcceptInvite token={token} />
            <form action={switchAccount.bind(null, token)} className="flex flex-wrap items-center justify-center gap-x-1 text-body-s text-muted">
              <span className="min-w-0 truncate">{t('signedInAs', { email: claims.email ?? '' })}</span>
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
