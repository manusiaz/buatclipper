// profile.anonymize (hapus akun, alur 12, AA-16): file foto profil di bucket publik avatars/{user_id}/ ikut dihapus lewat
// Storage API, sesudah isi profil dikosongkan bus_in.profile_anonymize. Policy hanya mengunci folder pertama = uid, jadi subfolder
// mungkin ada: entri folder (id null) dikosongkan rekursif — remove(folder) tidak menghapus apa pun dan akan berputar selamanya.
import type { BusEvent } from "../_shared/bus.ts";

export interface AvatarBucket {
  list(
    prefix: string,
    opts: { limit: number },
  ): Promise<{ data: { name: string; id: string | null }[] | null; error: unknown }>;
  remove(paths: string[]): Promise<{ error: unknown }>;
}

/** Hapus semua objek di bawah prefix; kembali jumlah yang dihapus (0 = tidak ada kemajuan → berhenti). */
async function removeFolder(bucket: AvatarBucket, prefix: string): Promise<number> {
  let removed = 0;
  for (;;) {
    const { data, error } = await bucket.list(prefix, { limit: 100 });
    if (error) throw error;
    let n = 0;
    for (const f of data ?? []) if (f.id === null) n += await removeFolder(bucket, `${prefix}/${f.name}`);
    const files = (data ?? []).filter((f) => f.id !== null).map((f) => `${prefix}/${f.name}`);
    if (files.length) {
      const { error: rmError } = await bucket.remove(files);
      if (rmError) throw rmError;
      n += files.length;
    }
    if (n === 0) return removed;
    removed += n;
  }
}

/** Hanya kiriman admin (satu-satunya pengirim profile.anonymize di allowlist): events mentah bisa memuat duplikat id yang dilewati
 * SQL sebelum cek allowlist, jadi topik saja tidak cukup (CX9). */
export async function removeAnonymizedAvatars(events: BusEvent[], bucket: AvatarBucket, from: string): Promise<void> {
  if (from !== "admin") return;
  for (const e of events) {
    if (e.topic === "profile.anonymize") await removeFolder(bucket, String(e.payload.user_id));
  }
}
