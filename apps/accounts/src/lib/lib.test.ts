import { describe, expect, it } from 'vitest';
import { dbCode, errorKeys } from './errors';
import { one, withParams } from './url';

describe('errorKeys', () => {
  it('tries accounts namespace, then shared errors, then generic', () => {
    expect(errorKeys('nik_taken')).toEqual({ keys: ['accounts.errors.nik_taken', 'errors.nik_taken', 'errors.generic'], param: '' });
  });
  it('maps nested codes and keeps the parameter', () => {
    expect(errorKeys('not_found:invite').keys[1]).toBe('errors.not_found.invite');
    expect(errorKeys('invalid:title')).toMatchObject({ param: 'title' });
  });
  it('aliases identity auth codes to auth.no_session', () => {
    expect(errorKeys('invalid_token').keys[1]).toBe('errors.auth.no_session');
    expect(errorKeys(undefined).keys[0]).toBe('accounts.errors.generic');
  });
});

describe('dbCode', () => {
  it('uses the machine code in message (market.fail)', () => {
    expect(dbCode({ code: 'P0001', message: 'invite_expired' })).toBe('invite_expired');
    expect(dbCode({ code: 'P0002', message: 'not_found:invite' })).toBe('not_found:invite');
  });
  it('prefers SQLSTATE overrides, then falls back', () => {
    expect(dbCode({ code: '23505', message: 'username abc sudah dipakai' }, { '23505': 'username_taken' })).toBe('username_taken');
    expect(dbCode({ code: '42501', message: 'butuh sesi identity' })).toBe('auth:no_session');
    expect(dbCode({ code: '22023', message: 'versi x bukan versi terbaru' })).toBe('generic');
    expect(dbCode(null)).toBe('generic');
  });
});

describe('url helpers', () => {
  it('appends params to relative and absolute targets', () => {
    expect(withParams('/kyc', { next: 'https://app.x/wallet?tab=1' })).toBe('/kyc?next=https%3A%2F%2Fapp.x%2Fwallet%3Ftab%3D1');
    expect(withParams('https://app.x/wallet/withdraw?tab=reward', { recipient_ref: 'r1' })).toBe(
      'https://app.x/wallet/withdraw?tab=reward&recipient_ref=r1',
    );
    expect(withParams('/', { next: undefined })).toBe('/');
  });
  it('one() takes the first repeated value', () => {
    expect(one(['a', 'b'])).toBe('a');
    expect(one(undefined)).toBeUndefined();
  });
});
