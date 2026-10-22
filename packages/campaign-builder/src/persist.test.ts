import { describe, expect, it } from 'vitest';
import { persistCampaign, splitSavePayload } from './persist';

describe('splitSavePayload', () => {
  it('jadwal, pool, rule, fee ke admin; isi + aset ke brand', () => {
    const { content, economics } = splitSavePayload({ id: 'c', title: 'T', assets: [], start_at: 's', pools: [], rules: [], fee_rule: null });
    expect(content).toEqual({ id: 'c', title: 'T', assets: [] });
    expect(economics).toEqual({ start_at: 's', pools: [], rules: [], fee_rule: null });
  });
});

describe('persistCampaign', () => {
  const noWait = () => Promise.resolve();
  it('brand dulu, lalu admin dengan content_version; mengulang selama replika belum tiba', async () => {
    const calls: unknown[] = [];
    let lag = 2;
    const brand = { rpc: (fn: string, args: Record<string, unknown>) => (calls.push(['brand', fn, args]), Promise.resolve({ data: { id: 'c1', content_version: 3 }, error: null })) };
    const core = {
      rpc: (fn: string, args: Record<string, unknown>) => {
        calls.push(['admin', fn, args]);
        return Promise.resolve(lag-- > 0 ? { data: null, error: { message: 'retry:replica_lag' } } : { data: 'c1', error: null });
      },
    };
    const r = await persistCampaign({ brand, core }, { title: 'T', org_id: 'o', pools: [1] }, true, noWait);
    expect(r).toEqual({ ok: true, id: 'c1' });
    expect(calls[0]).toEqual(['brand', 'save_campaign', { p_campaign: { title: 'T', org_id: 'o' } }]);
    expect(calls.slice(1)).toHaveLength(3);
    expect(calls[3]).toEqual(['admin', 'save_campaign', { p_campaign: { id: 'c1', content_version: 3, pools: [1] }, p_submit: true }]);
  });
  it('gagal di brand → admin tidak dipanggil; gagal di admin → error admin', async () => {
    const core = { rpc: () => Promise.resolve({ data: null, error: { message: 'invalid:rules', details: 'd' } }) };
    const bad = { rpc: () => Promise.resolve({ data: null, error: { message: 'slug_taken' } }) };
    expect(await persistCampaign({ brand: bad, core }, {}, false, noWait)).toEqual({ ok: false, error: 'slug_taken', detail: undefined });
    const ok = { rpc: () => Promise.resolve({ data: { id: 'c', content_version: 1 }, error: null }) };
    expect(await persistCampaign({ brand: ok, core }, {}, false, noWait)).toEqual({ ok: false, error: 'invalid:rules', detail: 'd' });
  });
});
