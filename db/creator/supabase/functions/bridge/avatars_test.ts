import assert from "node:assert/strict";
import { type AvatarBucket, removeAnonymizedAvatars } from "./avatars.ts";

// Storage tiruan: objek path penuh; list(prefix) = file langsung (id) + subfolder (id null), seperti Storage API.
function bucket(objects: string[], fail = false): AvatarBucket & { removed: string[] } {
  const removed: string[] = [];
  return {
    removed,
    list: (prefix) => {
      const names = new Map<string, string | null>();
      for (const o of objects.filter((o) => o.startsWith(prefix + "/"))) {
        const rest = o.slice(prefix.length + 1).split("/");
        names.set(rest[0], rest.length > 1 ? null : o);
      }
      return Promise.resolve({ data: [...names].map(([name, id]) => ({ name, id })), error: null });
    },
    remove: (paths) => {
      if (fail) return Promise.resolve({ error: new Error("storage down") });
      for (const p of paths) {
        const i = objects.indexOf(p);
        if (i >= 0) removed.push(...objects.splice(i, 1));
      }
      return Promise.resolve({ error: null });
    },
  };
}

Deno.test("avatar: profile.anonymize → semua file avatars/{user}/ dihapus; event lain tidak menyentuh storage", async () => {
  const b = bucket(["u1/a.webp", "u1/b.png", "u2/c.webp"]);
  await removeAnonymizedAvatars(
    [
      { id: "1", topic: "rep.row", payload: { table: "market.profiles" } },
      { id: "2", topic: "profile.anonymize", payload: { user_id: "u1" } },
    ],
    b,
    "admin",
  );
  assert.deepEqual(b.removed, ["u1/a.webp", "u1/b.png"]);
});

Deno.test("avatar: hapus gagal → error (bus mengulang batch)", async () => {
  await assert.rejects(() =>
    removeAnonymizedAvatars(
      [{ id: "1", topic: "profile.anonymize", payload: { user_id: "u1" } }],
      bucket(["u1/a.webp"], true),
      "admin",
    )
  );
});

Deno.test("avatar: subfolder (R85-1) dikosongkan rekursif, tidak berputar selamanya", async () => {
  const b = bucket(["u1/a.webp", "u1/x/b.webp", "u1/x/y/c.webp", "u2/d.webp"]);
  await removeAnonymizedAvatars([{ id: "1", topic: "profile.anonymize", payload: { user_id: "u1" } }], b, "admin");
  assert.deepEqual(b.removed.sort(), ["u1/a.webp", "u1/x/b.webp", "u1/x/y/c.webp"]);
});

Deno.test("avatar: CX9 — anonymize dari selain admin (mis. duplikat id di batch brand) tidak menghapus apa pun", async () => {
  const b = bucket(["u1/a.webp"]);
  await removeAnonymizedAvatars(
    [
      { id: "x", topic: "profile.ensure", payload: { user_id: "u9" } },
      { id: "x", topic: "profile.anonymize", payload: { user_id: "u1" } },
    ],
    b,
    "brand",
  );
  assert.deepEqual(b.removed, []);
});
