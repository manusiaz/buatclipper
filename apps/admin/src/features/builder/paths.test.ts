import { describe, expect, it } from 'vitest';
import { assetPath } from './paths';

const org = '11111111-1111-1111-1111-111111111111';
const c = '22222222-2222-2222-2222-222222222222';

describe('assetPath', () => {
  it('cover → public bucket, {org}/{campaign}/', () => {
    expect(assetPath('cover', org, c, 'Poster Final.PNG', 'ab12cd34')).toEqual({ bucket: 'campaign-covers', path: `${org}/${c}/cover-ab12cd34-Poster-Final.png` });
  });
  it('internal files go under internal/ (campaign_assets_internal_folder)', () => {
    const p = assetPath('internal', org, c, 'brief mentah (v2).pdf', 'x').path;
    expect(p).toBe(`${org}/${c}/internal/x-brief-mentah-v2.pdf`);
    expect(p.split('/')[2]).toBe('internal');
  });
  it('sanitises names and never escapes the folder', () => {
    const p = assetPath('asset', org, c, '../../etc/passwd', 'r').path;
    expect(p.startsWith(`${org}/${c}/`)).toBe(true);
    expect(p.split('/')).toHaveLength(3);
    expect(assetPath('asset', org, c, '.....', 'r').path).toBe(`${org}/${c}/r-file`);
  });
});
