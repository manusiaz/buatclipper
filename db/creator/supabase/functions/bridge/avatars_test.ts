import assert from "node:assert/strict";
import { type AvatarBucket, removeAnonymizedAvatars } from "./avatars.ts";

function bucket(files: Record<string, string[]>, fail = false): AvatarBucket & { removed: string[] } {
  const removed: string[] = [];
  return {
    removed,
    list: (prefix) => Promise.resolve({ data: (files[prefix] ?? []).map((name) => ({ name })), error: null }),
    remove: (paths) => {
      if (fail) return Promise.resolve({ error: new Error("storage down") });
      removed.push(...paths);
      for (const p of paths) {
        const [u, n] = p.split("/");
        files[u] = files[u].filter((f) => f !== n);
      }
      return Promise.resolve({ error: null });
    },
  };
}

Deno.test("avatar: profile.anonymize → semua file avatars/{user}/ dihapus; event lain tidak menyentuh storage", async () => {
  const b = bucket({ u1: ["a.webp", "b.png"], u2: ["c.webp"] });
  await removeAnonymizedAvatars([
    { id: "1", topic: "rep.row", payload: { table: "market.profiles" } },
    { id: "2", topic: "profile.anonymize", payload: { user_id: "u1" } },
  ], b);
  assert.deepEqual(b.removed, ["u1/a.webp", "u1/b.png"]);
});

Deno.test("avatar: hapus gagal → error (bus mengulang batch)", async () => {
  await assert.rejects(() =>
    removeAnonymizedAvatars(
      [{ id: "1", topic: "profile.anonymize", payload: { user_id: "u1" } }],
      bucket({ u1: ["a.webp"] }, true),
    )
  );
});
