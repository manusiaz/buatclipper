// Helper tes: fetch palsu yang mencatat panggilan, dan RPC palsu yang mencatat argumen.
import type { Rpc } from "./db.ts";

export interface Call {
  url: URL;
  method: string;
  headers: Headers;
  body: string;
}

export type Route = (call: Call) => Response | Promise<Response> | undefined;

export const jsonRes = (status: number, body: unknown, headers: HeadersInit = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });

/** fetch palsu: route pertama yang mengembalikan Response dipakai; tanpa route → error (tidak ada jaringan di tes). */
export function mockFetch(...routes: Route[]): { fetch: typeof fetch; calls: Call[] } {
  const calls: Call[] = [];
  const f = async (input: RequestInfo | URL, init: RequestInit = {}) => {
    const req = new Request(input, init);
    const call: Call = {
      url: new URL(req.url),
      method: req.method,
      headers: req.headers,
      body: init.body ? String(init.body) : await req.text(),
    };
    calls.push(call);
    for (const r of routes) {
      const res = await r(call);
      if (res) return res;
    }
    throw new Error(`unmocked ${call.method} ${call.url}`);
  };
  return { fetch: f as typeof fetch, calls };
}

/** Route berdasarkan host+path (tanpa query). */
export const on = (method: string, hostPath: string, fn: (c: Call) => Response | Promise<Response>): Route => (c) =>
  c.method === method && `${c.url.host}${c.url.pathname}` === hostPath ? fn(c) : undefined;

export interface RpcCall {
  fn: string;
  args: Record<string, unknown>;
}

/** RPC palsu: handler per nama fungsi; panggilan tanpa handler → error. */
export function fakeRpc(
  handlers: Record<string, (args: Record<string, unknown>) => unknown>,
): { rpc: Rpc; calls: RpcCall[] } {
  const calls: RpcCall[] = [];
  const rpc = (async (fn: string, args: Record<string, unknown> = {}) => {
    calls.push({ fn, args });
    const h = handlers[fn];
    if (!h) throw new Error(`unexpected rpc ${fn}`);
    return await h(args);
  }) as Rpc;
  return { rpc, calls };
}
