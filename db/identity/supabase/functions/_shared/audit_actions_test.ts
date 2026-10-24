// Regresi 2026-10-19: "pii.export_pph21" melanggar CHECK member.audit_logs.action (tanpa angka) → 500 di stack nyata,
// tapi lolos unit test karena rpc dimock. Semua literal action di fungsi dicek ke regex CHECK dari schema-nya langsung.
import { assert } from "@std/assert";

const sql = await Deno.readTextFile(new URL("../../schemas/member/audit_logs.sql", import.meta.url));
const check = new RegExp(sql.match(/action text not null check \(action ~ '([^']+)'\)/)![1]);

async function* sources(dir: URL): AsyncGenerator<URL> {
  for await (const e of Deno.readDir(dir)) {
    const u = new URL(e.name + (e.isDirectory ? "/" : ""), dir);
    if (e.isDirectory) yield* sources(u);
    else if (e.name.endsWith(".ts") && !e.name.endsWith("_test.ts")) yield u;
  }
}

Deno.test("semua action audit memenuhi CHECK member.audit_logs", async () => {
  const actions: string[] = [];
  for await (const f of sources(new URL("../", import.meta.url))) {
    const src = await Deno.readTextFile(f);
    for (const m of src.matchAll(/(?:p_action: |audit\(\w+, \w+, )"([^"]+)"/g)) actions.push(m[1]);
  }
  assert(actions.length >= 8, `action ditemukan: ${actions.length}`);
  const bad = actions.filter((a) => !check.test(a));
  assert(bad.length === 0, `melanggar ${check}: ${bad.join(", ")}`);
});
