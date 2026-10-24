// Segmen broadcast = kunci yang diterima api.send_broadcast / ops.dispatch_broadcasts:
// {platforms[], min_trust_score, max_trust_score, kyc: approved|not_approved, active_days}. Kosong = semua clipper aktif.
export const PLATFORM_KEYS = ['tiktok', 'instagram', 'youtube', 'threads', 'facebook', 'x'] as const;
export const CHANNELS = ['in_app', 'email', 'push'] as const;

export type Segment = {
  platforms?: string[];
  min_trust_score?: number;
  max_trust_score?: number;
  kyc?: 'approved' | 'not_approved';
  active_days?: number;
};

const int = (v: string | null | undefined, min: number, max: number) => {
  const s = (v ?? '').trim();
  if (!/^\d+$/.test(s)) return undefined;
  const n = Number(s);
  return n >= min && n <= max ? n : undefined;
};

export function segmentFrom(get: (k: string) => string | null): Segment {
  const seg: Segment = {};
  const platforms = PLATFORM_KEYS.filter((p) => get(`platform_${p}`) != null);
  if (platforms.length) seg.platforms = platforms;
  const min = int(get('min_trust_score'), 0, 100);
  const max = int(get('max_trust_score'), 0, 100);
  if (min !== undefined) seg.min_trust_score = min;
  if (max !== undefined) seg.max_trust_score = max;
  const kyc = get('kyc');
  if (kyc === 'approved' || kyc === 'not_approved') seg.kyc = kyc;
  const days = int(get('active_days'), 1, 3650);
  if (days !== undefined) seg.active_days = days;
  return seg;
}

export const channelsFrom = (get: (k: string) => string | null) => CHANNELS.filter((c) => get(`channel_${c}`) != null);
