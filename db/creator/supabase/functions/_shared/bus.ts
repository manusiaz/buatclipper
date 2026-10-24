// Penerima bus antar database (lihat schemas/bus/bus.sql). Dipanggil bridge bila header x-bridge-from ada:
//   x-bridge-from: nama project pengirim (identity|creator|brand|admin), x-bridge-ts/x-bridge-sig seperti bridge biasa,
//   secret = env BUS_SECRET_FROM_<PENGIRIM> (pasangan Vault bus_secret_<penerima> di pengirim).
//   body {"v":1,"action":"bus.deliver","payload":{"source":<pengirim>,"events":[{id,topic,payload}]}}
// Pengirim di body wajib sama dengan header (header ikut menentukan secret, body yang ditandatangani).
import { verifyBridge } from "./bridge.ts";
import type { Rpc } from "./db.ts";
import { env, HttpError, json } from "./http.ts";

export const BUS_PROJECTS = ["identity", "creator", "brand", "admin"] as const;

export function busSecret(from: string, read: (k: string) => string = env): string {
  if (!(BUS_PROJECTS as readonly string[]).includes(from)) throw new HttpError(401, "bad_source");
  return read(`BUS_SECRET_FROM_${from.toUpperCase()}`);
}

export type BusEvent = { id: string; topic: string; payload: Record<string, unknown> };

/** after: efek di luar DB (mis. hapus file Storage) sesudah batch diterapkan; gagal → 500, pengirim mengulang batch
 * (bus_receive idempoten, after dijalankan ulang). events = isi mentah kiriman (duplikat ikut, tanpa cek allowlist SQL):
 * after wajib memeriksa sendiri pengirim (from) yang berhak memicu efeknya. */
export async function handleBusDelivery(
  req: Request,
  rpc: Rpc,
  secret: (from: string) => string = busSecret,
  after?: (events: BusEvent[], from: string) => Promise<void>,
): Promise<Response> {
  const from = req.headers.get("x-bridge-from") ?? "";
  const msg = await verifyBridge(req, secret(from));
  if (msg.action !== "bus.deliver") throw new HttpError(400, "unknown_action", msg.action);
  if (msg.payload.source !== from) throw new HttpError(400, "bad_payload", "source ≠ x-bridge-from");
  if (!Array.isArray(msg.payload.events)) throw new HttpError(400, "bad_payload", "events wajib array");
  const data = await rpc("bus_receive", { p_source: from, p_events: msg.payload.events });
  if (after) await after(msg.payload.events as BusEvent[], from);
  return json(200, { ok: true, data });
}
