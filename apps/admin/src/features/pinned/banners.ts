/** Banner beranda (public.home.banners): [{img, href, alt}] — img URL https atau path publik, href path internal atau https. */
export interface Banner {
  img: string;
  href: string;
  alt: string;
}

const IMG = /^(https:\/\/\S+|\/?[A-Za-z0-9._\-/]+\.(webp|png|jpe?g|avif))$/;
const HREF = /^(\/[^\s]*|https:\/\/\S+)$/;

export function validBanners(list: unknown): Banner[] | null {
  if (!Array.isArray(list) || list.length > 10) return null;
  const out: Banner[] = [];
  for (const b of list as Partial<Banner>[]) {
    const img = String(b?.img ?? '').trim();
    const href = String(b?.href ?? '').trim();
    const alt = String(b?.alt ?? '').trim().slice(0, 120);
    if (!IMG.test(img) || !HREF.test(href) || href.startsWith('//')) return null;
    out.push({ img, href, alt });
  }
  return out;
}

export function parseBanners(value: unknown): Banner[] {
  if (!Array.isArray(value)) return [];
  return value.map((b) => ({ img: String(b?.img ?? ''), href: String(b?.href ?? ''), alt: String(b?.alt ?? '') }));
}
