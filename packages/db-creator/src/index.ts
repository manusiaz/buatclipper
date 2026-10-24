import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { Database } from './types.gen';

export type { Database } from './types.gen';
export type CreatorClient = SupabaseClient<Database, 'api'>;

/** Client Data API project creator (profil, storage avatar). accessToken = JWT sesi identity; tanpa itu = anon. */
export function createCreatorClient(accessToken?: () => Promise<string | null>): CreatorClient {
  return createClient<Database, 'api'>(process.env.NEXT_PUBLIC_CREATOR_DB_URL!, process.env.NEXT_PUBLIC_CREATOR_DB_PUBLISHABLE_KEY!, {
    db: { schema: 'api' },
    ...(accessToken ? { accessToken } : { auth: { persistSession: false, autoRefreshToken: false } }),
  });
}

/** Tunggu replika bus sampai di project lain (read-your-writes setelah tulis ke creator); false = belum sampai ~10 dtk. */
export async function untilReplicated(check: () => PromiseLike<boolean>, tries = 20, ms = 500): Promise<boolean> {
  for (let i = 0; i < tries; i++) {
    if (await check()) return true;
    await new Promise((r) => setTimeout(r, ms));
  }
  return false;
}
