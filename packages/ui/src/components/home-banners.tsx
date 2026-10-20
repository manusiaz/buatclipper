import { cn } from '../lib/cn';
import type { HomeBanner } from '../lib/banners';

/** Strip banner geser horizontal (snap), rasio 3:1; tautan https luar dibuka di tab baru. */
export function HomeBanners({ banners, className }: { banners: HomeBanner[]; className?: string }) {
  if (!banners.length) return null;
  return (
    <ul className={cn('-mx-4 flex snap-x snap-mandatory gap-3 overflow-x-auto px-4 pb-1 [scrollbar-width:none]', className)}>
      {banners.map((b, i) => {
        const external = b.href.startsWith('https://');
        return (
          <li key={`${b.img}-${i}`} className="w-[86%] shrink-0 snap-start sm:w-[48%] lg:w-[32%]">
            <a
              href={b.href}
              {...(external ? { target: '_blank', rel: 'noopener noreferrer' } : {})}
              className="block overflow-hidden rounded-card shadow-card focus-ring"
            >
              <img src={b.img} alt={b.alt} loading={i === 0 ? 'eager' : 'lazy'} className="aspect-[3/1] w-full object-cover" />
            </a>
          </li>
        );
      })}
    </ul>
  );
}
