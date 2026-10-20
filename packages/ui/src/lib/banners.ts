/** Banner beranda (E-25 public.home.banners, A6.2): [{img, href, alt}]. */
export interface HomeBanner {
  img: string;
  href: string;
  alt: string;
  /** Link https yang diisi admin (dibuka di tab baru); path internal = halaman app clipper. */
  external: boolean;
}

// Sama dengan validasi admin (features/pinned/banners.ts): path publik boleh tanpa "/" depan → dinormalkan.
const IMG = /^(https:\/\/\S+|\/?[A-Za-z0-9._\-/]+\.(webp|png|jpe?g|avif))$/;
const HREF = /^(\/(?!\/)[^\s]*|https:\/\/\S+)$/;

/**
 * Nilai setting mentah → banner yang aman dirender; entri rusak dibuang, maks 10. Path internal (link & gambar) milik app
 * clipper: dari host lain (landing) beri appBase = URL app supaya tidak 404 di host itu.
 */
export function parseHomeBanners(value: unknown, appBase = ''): HomeBanner[] {
  if (!Array.isArray(value)) return [];
  const local = (p: string) => (p.startsWith('https://') ? p : `${appBase}${p.startsWith('/') ? '' : '/'}${p}`);
  return value
    .map((b) => ({ img: String(b?.img ?? '').trim(), href: String(b?.href ?? '').trim(), alt: String(b?.alt ?? '').trim().slice(0, 120) }))
    .filter((b) => IMG.test(b.img) && HREF.test(b.href))
    .map((b) => ({ img: local(b.img), href: local(b.href), alt: b.alt, external: b.href.startsWith('https://') }))
    .slice(0, 10);
}
