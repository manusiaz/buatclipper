import { describe, expect, it } from 'vitest';
import { normalizeHashtag, normalizeLink, normalizeList, normalizeMention, splitChipInput } from './normalize';

describe('normalization (mirror of market.norm_list)', () => {
  it('hashtags: lowercase, leading # stripped, only letters/digits/_', () => {
    expect(normalizeHashtag(' #MPLID ')).toEqual({ value: 'mplid', ok: true });
    expect(normalizeHashtag('##Clipper_2026')).toEqual({ value: 'clipper_2026', ok: true });
    expect(normalizeHashtag('Kopi')).toEqual({ value: 'kopi', ok: true });
    expect(normalizeHashtag('#CaféLatte')).toEqual({ value: 'cafélatte', ok: true });
    expect(normalizeHashtag('#mpl id').ok).toBe(false);
    expect(normalizeHashtag('#mpl-id').ok).toBe(false);
    expect(normalizeHashtag('#')).toEqual({ value: '', ok: true });
  });

  it('mentions: lowercase, leading @ stripped, letters/digits/_/.', () => {
    expect(normalizeMention('@StudioSatu')).toEqual({ value: 'studiosatu', ok: true });
    expect(normalizeMention('@studio.satu_1')).toEqual({ value: 'studio.satu_1', ok: true });
    expect(normalizeMention('@studio-satu').ok).toBe(false);
  });

  it('links: https only; no scheme → https://; scheme lowercased', () => {
    expect(normalizeLink('studio.id/promo')).toEqual({ value: 'https://studio.id/promo', ok: true });
    expect(normalizeLink(' https://a.b/c?d=1 ')).toEqual({ value: 'https://a.b/c?d=1', ok: true });
    expect(normalizeLink('HTTPS://A.b')).toEqual({ value: 'https://A.b', ok: true });
    expect(normalizeLink('http://studio.id').ok).toBe(false);
    expect(normalizeLink('javascript://alert(1)').ok).toBe(false);
    expect(normalizeLink('https://a b').ok).toBe(false);
  });

  it('lists: trims, drops empty and duplicate entries, reports invalid ones', () => {
    expect(normalizeList('hashtag', ['#MPLID', ' Clipper ', '#mplid', '', 'bad tag'])).toEqual({ values: ['mplid', 'clipper'], invalid: ['bad tag'] });
    expect(normalizeList('text', [' Pakai subtitle ', '', 'Pakai subtitle'])).toEqual({ values: ['Pakai subtitle'], invalid: [] });
  });

  it('chip input splitting', () => {
    expect(splitChipInput('hashtag', '#a, #b  #c')).toEqual(['#a', '#b', '#c']);
    expect(splitChipInput('text', 'Pakai subtitle\nJangan pakai musik')).toEqual(['Pakai subtitle', 'Jangan pakai musik']);
  });
});
