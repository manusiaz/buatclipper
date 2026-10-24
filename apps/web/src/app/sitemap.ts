import type { MetadataRoute } from 'next';
import { hosts } from '@clipper/auth';
import { getLiveSlugs } from '@/features/campaign-public/data';
import { LEGAL_DOCS } from '@/features/legal/docs';

export const revalidate = 3600;

/** §15.2: {domain} diindeks — landing, legal, dan /c/[slug] campaign live publik (RLS anon). */
export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const base = hosts.web.replace(/\/+$/, '');
  const campaigns = await getLiveSlugs().catch(() => []);
  return [
    { url: `${base}/`, changeFrequency: 'daily', priority: 1 },
    ...campaigns.map((c) => ({
      url: `${base}/c/${c.slug}`,
      lastModified: c.updated ?? undefined,
      changeFrequency: 'daily' as const,
      priority: 0.8,
    })),
    ...LEGAL_DOCS.map((d) => ({ url: `${base}/legal/${d}`, changeFrequency: 'monthly' as const, priority: 0.3 })),
  ];
}
