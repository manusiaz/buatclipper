import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { AuthShell, Button } from '@clipper/ui';

export const metadata: Metadata = { title: 'Offline' };

// Disimpan service worker saat dipasang; ditampilkan kalau navigasi gagal karena tidak ada koneksi. Tanpa JS.
export default async function OfflinePage() {
  const t = await getTranslations('clipper.offline');
  return (
    <AuthShell title={t('title')} description={t('body')}>
      <Button href="/campaigns" fullWidth iconLeft="refresh">
        {t('retry')}
      </Button>
    </AuthShell>
  );
}
