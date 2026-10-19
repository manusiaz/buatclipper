import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { hosts } from '@clipper/auth';
import { getAuth, requireClipper } from '@clipper/auth/server';
import { identityApi } from '@clipper/db-identity';
import { Button, Card, CardDescription, CardHeader, CardTitle, ThemeToggle } from '@clipper/ui';
import { core } from '@/features/lib/server';
import { LanguageSwitch } from '@/features/settings/language';
import { PromoSwitch } from '@/features/settings/promo-switch';
import { PushCard } from '@/features/settings/push-card';
import { SignOutButton } from '@/features/settings/sign-out';

export const metadata: Metadata = { title: 'Pengaturan' };

// F-C11, F-C14, F-C18 / C2.5, C3.2: bahasa, tema, email promosi (E-34), push per perangkat (E-36).
export default async function SettingsPage() {
  const { claims } = await requireClipper();
  const { supabase } = await getAuth('sso');
  const db = await core();
  const [t, tc, prefs, subs] = await Promise.all([
    getTranslations('clipper.settings'),
    getTranslations('common'),
    db.from('notification_prefs').select('email_promotions').eq('user_id', claims.sub).maybeSingle(),
    identityApi(supabase).from('push_subscriptions').select('id', { count: 'exact', head: true }),
  ]);

  return (
    <div className="flex flex-col gap-4">
      <Card className="flex flex-col gap-4">
        <CardHeader>
          <CardTitle>{t('display')}</CardTitle>
        </CardHeader>
        <LanguageSwitch />
        <div className="flex flex-col gap-2">
          <p className="text-label text-ink">{t('theme')}</p>
          <ThemeToggle
            variant="segmented"
            labels={{ light: tc('themeLight'), dark: tc('themeDark'), system: tc('themeSystem'), toggle: tc('theme') }}
          />
        </div>
      </Card>
      <Card className="flex flex-col gap-4">
        <CardHeader>
          <CardTitle>{t('notifications')}</CardTitle>
          <CardDescription>{t('notificationsBody')}</CardDescription>
        </CardHeader>
        <PromoSwitch initial={prefs.data?.email_promotions ?? true} />
        <div className="border-t border-border pt-4">
          <PushCard devices={subs.count ?? 0} />
        </div>
      </Card>
      <Card className="flex flex-col gap-3">
        <CardHeader>
          <CardTitle>{t('account')}</CardTitle>
          <CardDescription>{t('accountBody')}</CardDescription>
        </CardHeader>
        <Button
          href={`${hosts.accounts}/?next=${encodeURIComponent(`${hosts.app}/settings`)}`}
          variant="secondary"
          iconLeft="manage_accounts"
          fullWidth
        >
          {t('accountAction')}
        </Button>
        <SignOutButton />
      </Card>
    </div>
  );
}
