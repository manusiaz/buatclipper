import { cookies } from 'next/headers';
import { getRequestConfig } from 'next-intl/server';
import { LOCALE_COOKIE, loadMessages, resolveLocale } from '@clipper/i18n';

export default getRequestConfig(async () => {
  const locale = resolveLocale((await cookies()).get(LOCALE_COOKIE)?.value);
  return { locale, timeZone: 'Asia/Jakarta', messages: await loadMessages(locale, ['common', 'errors', 'notifications', 'brand', 'builder']) };
});
