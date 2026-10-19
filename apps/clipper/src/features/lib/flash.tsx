'use client';

import { useEffect, useRef } from 'react';
import { toast } from '@clipper/ui';

/** Toast sekali setelah redirect (mis. ?connected=tiktok, ?submitted=1). */
export function Flash({ message, tone = 'success' }: { message: string; tone?: 'success' | 'error' }) {
  const shown = useRef(false);
  useEffect(() => {
    if (shown.current) return;
    shown.current = true;
    if (tone === 'error') toast.error(message);
    else toast.success(message);
  }, [message, tone]);
  return null;
}
