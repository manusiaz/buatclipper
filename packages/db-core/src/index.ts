import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { Database } from './types.gen';

export type { Database } from './types.gen';
export type CoreClient = SupabaseClient<Database, 'api'>;
export type CoreView<V extends keyof Database['api']['Views']> = Database['api']['Views'][V]['Row'];
export type CoreFn<F extends keyof Database['api']['Functions']> = Database['api']['Functions'][F];

/** Client Data API core (schema api). accessToken = JWT sesi identity (Custom OIDC, PRD §15.6); tanpa itu = anon. */
export function createCoreClient(accessToken?: () => Promise<string | null>): CoreClient {
  return createClient<Database, 'api'>(process.env.NEXT_PUBLIC_CORE_URL!, process.env.NEXT_PUBLIC_CORE_PUBLISHABLE_KEY!, {
    db: { schema: 'api' },
    ...(accessToken ? { accessToken } : { auth: { persistSession: false, autoRefreshToken: false } }),
  });
}
