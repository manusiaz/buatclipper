import { describe, expect, it } from 'vitest';
import { consentSummary } from './consents';

describe('consentSummary', () => {
  it('prefers the newest active row and keeps CONSENT_KINDS order', () => {
    const rows = [
      { kind: 'privacy', version: '2026-01-01', granted_at: '2026-01-01T00:00:00Z', revoked_at: null },
      { kind: 'privacy', version: '2026-10-19', granted_at: '2026-10-19T00:00:00Z', revoked_at: null },
      { kind: 'tos_clipper', version: '2026-10-19', granted_at: '2026-10-19T00:00:00Z', revoked_at: null },
    ];
    const s = consentSummary(rows);
    expect(s.map((c) => c.kind)).toEqual(['tos_clipper', 'privacy', 'share_with_brand']);
    expect(s[1]).toMatchObject({ active: true, version: '2026-10-19' });
    expect(s[2]).toMatchObject({ active: false, grantedAt: null });
  });
  it('shows the latest revoked row when nothing is active', () => {
    const rows = [
      { kind: 'kyc', version: '2026-05-01', granted_at: '2026-05-01T00:00:00Z', revoked_at: '2026-06-01T00:00:00Z' },
      { kind: 'kyc', version: '2026-04-01', granted_at: '2026-04-01T00:00:00Z', revoked_at: '2026-04-02T00:00:00Z' },
    ];
    expect(consentSummary(rows)[0]).toMatchObject({ kind: 'kyc', active: false, version: '2026-05-01' });
  });
});
