import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { Database } from './types.gen';

export type { Database } from './types.gen';
export type BrandClient = SupabaseClient<Database, 'api'>;
export type BrandView<V extends keyof Database['api']['Views']> = Database['api']['Views'][V]['Row'];

/** Client Data API project brand (org, tim, undangan, agency). accessToken = JWT sesi identity; tanpa itu = anon. */
export function createBrandClient(accessToken?: () => Promise<string | null>): BrandClient {
  return createClient<Database, 'api'>(process.env.NEXT_PUBLIC_BRAND_DB_URL!, process.env.NEXT_PUBLIC_BRAND_DB_PUBLISHABLE_KEY!, {
    db: { schema: 'api' },
    ...(accessToken ? { accessToken } : { auth: { persistSession: false, autoRefreshToken: false } }),
  });
}
