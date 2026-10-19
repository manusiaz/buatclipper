import createNextIntlPlugin from 'next-intl/plugin';
import { clipperNextConfig } from '@clipper/config/next';

export default createNextIntlPlugin('./src/i18n/request.ts')(clipperNextConfig({ app: 'clipper' }));
