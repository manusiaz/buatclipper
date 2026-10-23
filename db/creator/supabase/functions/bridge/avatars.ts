// profile.anonymize (hapus akun, alur 12, AA-16): file foto profil di bucket publik avatars/{user_id}/ ikut dihapus lewat
// Storage API, sesudah isi profil dikosongkan bus_in.profile_anonymize.
import type { BusEvent } from "../_shared/bus.ts";

export interface AvatarBucket {
  list(prefix: string, opts: { limit: number }): Promise<{ data: { name: string }[] | null; error: unknown }>;
  remove(paths: string[]): Promise<{ error: unknown }>;
}

export async function removeAnonymizedAvatars(events: BusEvent[], bucket: AvatarBucket): Promise<void> {
  for (const e of events) {
    if (e.topic !== "profile.anonymize") continue;
    const userId = String(e.payload.user_id);
    for (;;) {
      const { data, error } = await bucket.list(userId, { limit: 100 });
      if (error) throw error;
      if (!data?.length) break;
      const { error: rmError } = await bucket.remove(data.map((f) => `${userId}/${f.name}`));
      if (rmError) throw rmError;
    }
  }
}
