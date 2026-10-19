import { cache } from 'react';
import { coreServer } from '@clipper/auth/server';

/** Nama tampilan untuk menu avatar. */
export const myName = cache(async (email?: string): Promise<string> => {
  const core = await coreServer();
  const { data } = await core.from('my_profile').select('display_name, username').maybeSingle();
  return data?.display_name || data?.username || email || 'Brand';
});
