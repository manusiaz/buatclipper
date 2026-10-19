import type { MetadataRoute } from 'next';
import { hosts } from '@clipper/auth';

/** /r/[token] = laporan privat bertoken: jangan dirayapi. */
export default function robots(): MetadataRoute.Robots {
  const base = hosts.web.replace(/\/+$/, '');
  return { rules: [{ userAgent: '*', allow: '/', disallow: '/r/' }], sitemap: `${base}/sitemap.xml` };
}
