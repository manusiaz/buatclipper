/** Banner beranda (E-25 public.home.banners, A6.2): [{img, href, alt}]. */
export interface HomeBanner {
  img: string;
  href: string;
  alt: string;
}

// Sama dengan validasi admin (features/pinned/banners.ts): path publik boleh tanpa "/" depan → dinormalkan.
const IMG = /^(https:\/\/\S+|\/?[A-Za-z0-9._\-/]+\.(webp|png|jpe?g|avif))$/;
const HREF = /^(\/(?!\/)[^\s]*|https:\/\/\S+)$/;

/** Nilai setting mentah → banner yang aman dirender; entri rusak dibuang, maks 10. */
export function parseHomeBanners(value: unknown): HomeBanner[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((b) => ({ img: String(b?.img ?? '').trim(), href: String(b?.href ?? '').trim(), alt: String(b?.alt ?? '').trim().slice(0, 120) }))
    .filter((b) => IMG.test(b.img) && HREF.test(b.href))
    .map((b) => (b.img.startsWith('https://') || b.img.startsWith('/') ? b : { ...b, img: `/${b.img}` }))
    .slice(0, 10);
}
