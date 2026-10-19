import type { SupabaseClient } from '@supabase/supabase-js';
import type { Database } from './types.gen';

export type { Database } from './types.gen';
export type IdentityView<V extends keyof Database['api']['Views']> = Database['api']['Views'][V]['Row'];

/**
 * Data member milik sendiri (schema api identity). Client-nya = client sesi dari @clipper/auth (schema bawaan public →
 * PGRST106), jadi schema api dipilih di sini. Hanya accounts, clipper, admin.
 */
export function identityApi(client: SupabaseClient) {
  return (client as unknown as SupabaseClient<Database>).schema('api');
}

/** URL Edge Function identity (member-data, pii-export, delete-account, admin-auth). */
export function identityFunctionUrl(name: 'member-data' | 'pii-export' | 'delete-account' | 'admin-auth'): string {
  return `${process.env.NEXT_PUBLIC_IDENTITY_URL}/functions/v1/${name}`;
}
