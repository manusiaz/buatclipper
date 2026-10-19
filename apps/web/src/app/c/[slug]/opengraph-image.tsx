import { ImageResponse } from 'next/og';
import { getLocale, getTranslations } from 'next-intl/server';
import { formatIDR, platformLabels, type UiLocale } from '@clipper/ui';
import { coverUrl } from '@/lib/cover';
import { idrRates } from '@/lib/rates';
import { getPublicCampaign } from '@/features/campaign-public/data';

export const size = { width: 1200, height: 630 };
export const contentType = 'image/png';
export const alt = 'Clipper';

const TYPES = ['image/jpeg', 'image/png', 'image/webp'];
// Ikon "send" Material Symbols (sama dengan LogoMark DS).
const PLANE = 'M162-178q-15 6-28.5-2.5T120-205v-200l302-75-302-77v-198q0-16 13.5-24.5T162-782l652 274q18 8 18 28t-18 28L162-178Z';

/** Cover diambil sendiri (bukan URL langsung ke satori): batas ukuran, tipe, dan waktu; gagal → tanpa cover. */
async function coverData(path: string | null): Promise<string | null> {
  const url = coverUrl(path);
  if (!url) return null;
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(3000) });
    const type = res.headers.get('content-type')?.split(';')[0] ?? '';
    if (!res.ok || !TYPES.includes(type)) return null;
    const buf = Buffer.from(await res.arrayBuffer());
    return buf.byteLength <= 2 * 1024 * 1024 ? `data:${type};base64,${buf.toString('base64')}` : null;
  } catch {
    return null;
  }
}

// Warna = token DS (navy, brand-500, brand-300); satori tidak membaca CSS variable.
export default async function Image({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const [data, t, locale] = await Promise.all([
    getPublicCampaign(slug).catch(() => null),
    getTranslations('web.campaign'),
    getLocale() as Promise<UiLocale>,
  ]);
  const c = data?.campaign;
  const top = data ? Math.max(0, ...idrRates(data.rules, data.campaign.platforms).map((r) => r.ratePer1k)) : 0;
  const cover = await coverData(data?.coverPath ?? null);
  const title = c?.title ?? 'Clipper';

  return new ImageResponse(
    (
      <div style={{ display: 'flex', width: '100%', height: '100%', background: '#0a1226', color: '#ffffff' }}>
        {cover ? (
          <img src={cover} alt="" width={520} height={630} style={{ width: 520, height: 630, objectFit: 'cover' }} />
        ) : null}
        <div
          style={{
            display: 'flex',
            flexDirection: 'column',
            justifyContent: 'space-between',
            flex: 1,
            padding: 64,
            backgroundImage: 'radial-gradient(90% 70% at 100% 0%, #1e3470 0%, #0a1226 60%)',
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 16, fontSize: 34, fontWeight: 700 }}>
            <div
              style={{
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                width: 52,
                height: 52,
                borderRadius: 16,
                backgroundImage: 'linear-gradient(160deg, #4d7dff, #1d5bff 55%, #0f47e0)',
              }}
            >
              <svg width="30" height="30" viewBox="0 -960 960 960" style={{ transform: 'rotate(-32deg)' }}>
                <path fill="#ffffff" d={PLANE} />
              </svg>
            </div>
            Clipper
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 24 }}>
            <div style={{ display: 'flex', fontSize: title.length > 60 ? 48 : 60, fontWeight: 700, lineHeight: 1.1, letterSpacing: -1.5 }}>
              {title.length > 110 ? `${title.slice(0, 107)}…` : title}
            </div>
            {top > 0 ? (
              <div style={{ display: 'flex', alignItems: 'baseline', gap: 14 }}>
                <span style={{ fontSize: 64, fontWeight: 700, color: '#a9c1ff' }}>{formatIDR(top, { locale })}</span>
                <span style={{ fontSize: 30, color: '#c9d3ea' }}>{t('per1k')}</span>
              </div>
            ) : null}
          </div>
          <div style={{ display: 'flex', gap: 12, fontSize: 26, color: '#c9d3ea' }}>
            {(c?.platforms ?? []).slice(0, 4).map((p) => (
              <span key={p} style={{ display: 'flex', padding: '8px 18px', borderRadius: 999, background: '#1e2a4a' }}>
                {platformLabels[p]}
              </span>
            ))}
          </div>
        </div>
      </div>
    ),
    size,
  );
}
