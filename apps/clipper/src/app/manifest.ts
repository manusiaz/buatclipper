import type { MetadataRoute } from 'next';

// F-C14: PWA terpasang membuka /campaigns. Warna = token DS (page light & primary).
export default function manifest(): MetadataRoute.Manifest {
  return {
    id: '/',
    name: 'Clipper',
    short_name: 'Clipper',
    description: 'Ambil campaign, posting di akun sendiri, dibayar per 1.000 views.',
    lang: 'id',
    start_url: '/campaigns',
    scope: '/',
    display: 'standalone',
    orientation: 'portrait',
    background_color: '#F6F8FC',
    theme_color: '#1D5BFF',
    categories: ['business', 'productivity', 'social'],
    icons: [
      { src: '/icons/icon-192.png', sizes: '192x192', type: 'image/png', purpose: 'any' },
      { src: '/icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'any' },
      { src: '/icons/maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
    ],
    shortcuts: [
      { name: 'Tugas', url: '/tasks', icons: [{ src: '/icons/icon-192.png', sizes: '192x192' }] },
      { name: 'Wallet', url: '/wallet', icons: [{ src: '/icons/icon-192.png', sizes: '192x192' }] },
    ],
  };
}
