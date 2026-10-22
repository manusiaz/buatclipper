import createNextIntlPlugin from 'next-intl/plugin';
import { clipperNextConfig } from '@clipper/config/next';

// Cover campaign = storage publik project brand.
const brand = new URL(process.env.NEXT_PUBLIC_BRAND_DB_URL ?? 'http://127.0.0.1:57321');
const local = ['127.0.0.1', 'localhost'].includes(brand.hostname);

export default createNextIntlPlugin('./src/i18n/request.ts')(
  clipperNextConfig({
    app: 'web',
    extra: {
      images: {
        remotePatterns: [
          {
            protocol: brand.protocol === 'https:' ? 'https' : 'http',
            hostname: brand.hostname,
            port: brand.port,
            pathname: '/storage/v1/object/public/campaign-covers/**',
          },
        ],
        // Stack Supabase lokal di 127.0.0.1; produksi selalu host publik.
        dangerouslyAllowLocalIP: local,
      },
      outputFileTracingIncludes: { '/legal/*': ['./content/legal/**'] },
    },
  }),
);
