import { getTranslations } from 'next-intl/server';
import { ThemeToggle } from '@clipper/ui';

export async function ThemeSwitch() {
  const t = await getTranslations('common');
  return <ThemeToggle labels={{ light: t('themeLight'), dark: t('themeDark'), system: t('themeSystem'), toggle: t('theme') }} />;
}
