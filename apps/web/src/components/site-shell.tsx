import type { ReactNode } from 'react';
import Link from 'next/link';
import { getTranslations } from 'next-intl/server';
import { Button, PublicShell, ThemeToggle } from '@clipper/ui';
import { LocaleSwitch } from '@/features/locale/locale-switch';
import { clipperHref, hasSession } from '@/lib/session';

/** Header + footer {domain} (§6.8 "web"): CTA clipper berubah jadi Buka app kalau cookie sesi SSO ada. */
export async function SiteShell({ children }: { children: ReactNode }) {
  const [t, tc, session] = await Promise.all([getTranslations('web'), getTranslations('common'), hasSession()]);
  const year = new Intl.DateTimeFormat('en', { year: 'numeric', timeZone: 'Asia/Jakarta' }).format(new Date());

  return (
    <div data-site-shell="" className="contents">
      <PublicShell
        linkAs={Link}
        labels={{ openMenu: t('nav.openMenu'), closeMenu: t('nav.closeMenu'), nav: t('nav.main'), footer: t('nav.footer') }}
        nav={[
          { href: '/#campaigns', label: t('nav.campaigns'), icon: 'campaign' },
          { href: '/#cara-kerja', label: t('nav.how'), icon: 'checklist' },
          { href: '/#cara-bayar', label: t('nav.payout'), icon: 'payments' },
          { href: '/#brand', label: t('nav.brand'), icon: 'storefront' },
          { href: '/#faq', label: t('nav.faq'), icon: 'help' },
        ]}
        headerExtras={
          <>
            <LocaleSwitch />
            <ThemeToggle labels={{ light: tc('themeLight'), dark: tc('themeDark'), system: tc('themeSystem'), toggle: tc('theme') }} />
          </>
        }
        secondaryAction={
          session ? undefined : (
            <Button href={clipperHref(false)} variant="ghost" size="sm">
              {t('nav.login')}
            </Button>
          )
        }
        cta={
          <Button href={clipperHref(session)} size="sm">
            {session ? t('nav.openApp') : t('nav.start')}
          </Button>
        }
        footer={{
          tagline: t('footer.tagline'),
          columns: [
            {
              title: t('footer.colClipper'),
              links: [
                { label: t('footer.findCampaign'), href: '/#campaigns' },
                { label: t('nav.how'), href: '/#cara-kerja' },
                { label: t('nav.payout'), href: '/#cara-bayar' },
                { label: t('nav.faq'), href: '/#faq' },
              ],
            },
            {
              title: t('footer.colBrand'),
              links: [
                { label: t('nav.brand'), href: '/#brand' },
                { label: t('footer.managed'), href: '/#brand-managed' },
              ],
            },
            {
              title: t('footer.colLegal'),
              links: [
                { label: t('legal.titles.tos-clipper'), href: '/legal/tos-clipper' },
                { label: t('legal.titles.tos-brand'), href: '/legal/tos-brand' },
                { label: t('legal.titles.privacy'), href: '/legal/privacy' },
              ],
            },
          ],
          bottom: t('footer.rights', { year }),
        }}
      >
        {children}
      </PublicShell>
    </div>
  );
}
