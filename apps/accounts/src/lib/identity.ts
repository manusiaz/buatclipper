import { getAuth } from '@clipper/auth/server';
import { identityApi } from '@clipper/db-identity';

/** Data API identity (schema api) dengan sesi user. Client Auth bawaan memakai schema public, jadi dipilih eksplisit. */
export async function identityDb() {
  const { supabase } = await getAuth('sso');
  return identityApi(supabase);
}
