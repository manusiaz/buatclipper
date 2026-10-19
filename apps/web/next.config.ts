import createNextIntlPlugin from 'next-intl/plugin';
import { clipperNextConfig } from '@clipper/config/next';

const core = new URL(process.env.NEXT_PUBLIC_CORE_URL ?? 'http://127.0.0.1:55321');
const local = ['127.0.0.1', 'localhost'].includes(core.hostname);

export default createNextIntlPlugin('./src/i18n/request.ts')(
  clipperNextConfig({
    app: 'web',
    extra: {
      images: {
        remotePatterns: [
          {
            protocol: core.protocol === 'https:' ? 'https' : 'http',
            hostname: core.hostname,
            port: core.port,
            pathname: '/storage/v1/object/public/campaign-covers/**',
          },
        ],
        // Stack Supabase lokal di 127.0.0.1; produksi selalu host publik.
        dangerouslyAllowLocalIP: local,
      },
      outputFileTracingIncludes: { '/legal/[doc]': ['./content/legal/**'] },
    },
  }),
);
