import createNextIntlPlugin from 'next-intl/plugin';
import { clipperNextConfig } from '@clipper/config/next';

// Bukti transfer ≤ 10 MB (bucket payout-proofs) lewat Server Action → batas body action & proxy dinaikkan.
export default createNextIntlPlugin('./src/i18n/request.ts')(
  clipperNextConfig({ app: 'admin', extra: { experimental: { serverActions: { bodySizeLimit: '11mb' }, proxyClientMaxBodySize: '11mb' } } }),
);
