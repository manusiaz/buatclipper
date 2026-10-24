import createNextIntlPlugin from 'next-intl/plugin';
import { clipperNextConfig } from '@clipper/config/next';

// Cover campaign = storage publik project brand.
const brand = new URL(process.env.NEXT_PUBLIC_BRAND_DB_URL ?? 'http://127.0.0.1:57321');

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
        // Host cover resolve ke alamat privat: dev 127.0.0.1, deploy (deploy.sh extra_hosts) Caddy server sendiri. Aman dari
        // SSRF karena remotePatterns mengunci host + path ke storage cover brand; URL lain tetap ditolak.
        dangerouslyAllowLocalIP: true,
      },
      outputFileTracingIncludes: { '/legal/*': ['./content/legal/**'] },
    },
  }),
);
