// Empat tujuan utama: nama route tab, kunci i18n clipper.mobile.tabs, ikon Material (Android/web) & SF Symbol (iOS).
import type { IconName } from './core';

export const TAB_KEYS = [
  ['(campaigns)', 'campaigns'],
  ['clips', 'clips'],
  ['wallet', 'wallet'],
  ['account', 'account'],
] as const;

export const TAB_ICONS: Record<string, IconName> = { '(campaigns)': 'explore', clips: 'movie', wallet: 'account_balance_wallet', account: 'person' };

/** Nama SF Symbol (dicek di SF Symbols 5, iOS 17+). */
export const TAB_SF: Record<string, { default: string; selected: string }> = {
  '(campaigns)': { default: 'safari', selected: 'safari.fill' },
  clips: { default: 'film', selected: 'film.fill' },
  wallet: { default: 'wallet.bifold', selected: 'wallet.bifold.fill' },
  account: { default: 'person.crop.circle', selected: 'person.crop.circle.fill' },
};
