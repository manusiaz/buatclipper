'use client';

import { useTranslations } from 'next-intl';
import { Button, toast } from '@clipper/ui';

/** Web Share API (HP) dengan cadangan salin ke clipboard. */
export function ShareButton({ url, text }: { url: string; text: string }) {
  const t = useTranslations('clipper.referral');
  const share = async () => {
    if (navigator.share) {
      try {
        await navigator.share({ title: 'Clipper', text, url });
        return;
      } catch (e) {
        if (e instanceof DOMException && e.name === 'AbortError') return;
      }
    }
    try {
      await navigator.clipboard.writeText(`${text} ${url}`);
      toast.success(t('copiedLink'));
    } catch {
      toast.error(t('copyFailed'));
    }
  };
  return (
    <Button fullWidth size="lg" iconLeft="share" onClick={share}>
      {t('share')}
    </Button>
  );
}
