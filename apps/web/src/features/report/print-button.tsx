'use client';

import { useEffect } from 'react';
import { Button } from '@clipper/ui';

/**
 * PDF = versi cetak halaman ini (F-B09). Kertas selalu terang: kelas `dark` dilepas selama cetak (termasuk Ctrl+P),
 * karena browser tidak mencetak background dan teks terang jadi tidak terbaca.
 */
export function PrintButton({ label }: { label: string }) {
  useEffect(() => {
    const html = document.documentElement;
    let wasDark = false;
    const before = () => {
      wasDark = html.classList.contains('dark');
      if (wasDark) html.classList.remove('dark');
    };
    const after = () => {
      if (wasDark) html.classList.add('dark');
    };
    window.addEventListener('beforeprint', before);
    window.addEventListener('afterprint', after);
    return () => {
      window.removeEventListener('beforeprint', before);
      window.removeEventListener('afterprint', after);
    };
  }, []);
  return (
    <Button variant="secondary" iconLeft="download" onClick={() => window.print()} className="print:hidden">
      {label}
    </Button>
  );
}
