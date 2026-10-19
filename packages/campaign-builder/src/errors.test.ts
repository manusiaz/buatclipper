import { describe, expect, it } from 'vitest';
import { mapServerError } from './errors';

const m = (code: string) => {
  const r = mapServerError(code, 'detail id');
  return `${r.step}/${r.field}:${r.message}`;
};

describe('mapServerError', () => {
  it('maps save_campaign machine codes to step + field', () => {
    expect(m('invalid:title')).toBe('basics/title:server.invalidField');
    expect(m('slug_taken')).toBe('basics/slug:server.slugTaken');
    expect(m('invalid:slug')).toBe('basics/slug:errors.slugFormat');
    expect(m('invalid:required_hashtags')).toBe('brief/required_hashtags:errors.hashtag');
    expect(m('invalid:example_urls')).toBe('brief/example_urls:errors.linkHttps');
    expect(m('invalid:asset_path')).toBe('brief/assets:server.assetPath');
    expect(m('invalid:reward_type')).toBe('rewards/pools:server.rewardType');
    expect(m('invalid:rule_params')).toBe('rewards/rules:server.ruleParams');
    expect(m('invalid:rule_platform')).toBe('rewards/rules:errors.rulePlatform');
    expect(m('invalid:pool')).toBe('budget/pools:server.pool');
    expect(m('pools_locked_after_payment')).toBe('budget/pools:server.poolsLocked');
    expect(m('invalid:schedule')).toBe('schedule/start_at:server.schedule');
    expect(m('invalid:submit_deadline')).toBe('schedule/submit_deadline:errors.deadlinePast');
    expect(m('org_not_verified')).toBe('summary/null:server.orgNotVerified');
    expect(m('invalid:template')).toBe('summary/null:errors.templateSubmit');
    expect(m('campaign_locked')).toBe('null/null:server.locked');
    expect(m('auth:forbidden')).toBe('null/null:server.forbidden');
    expect(m('org_suspended')).toBe('null/null:server.orgSuspended');
  });

  it('maps Postgres constraint / not-null / trigger messages', () => {
    expect(m('new row for relation "campaigns" violates check constraint "campaigns_title_check"')).toBe('basics/title:errors.titleLength');
    expect(m('new row for relation "campaigns" violates check constraint "campaigns_level_has_threshold"')).toBe(
      'eligibility/min_trust_score:errors.levelNeedsTrust',
    );
    expect(m('insert or update on table "campaigns" violates foreign key constraint "campaigns_category_id_fkey"')).toBe('basics/category_id:server.category');
    expect(m('null value in column "platforms" of relation "campaigns" violates not-null constraint')).toBe('platforms/platforms:errors.required');
    expect(m('campaigns: brief terkunci sejak diajukan (status in_review); yang boleh diubah hanya FAQ')).toBe('null/null:server.locked');
  });

  it('falls back to a generic message and keeps the detail', () => {
    const r = mapServerError('something_else', 'penjelasan');
    expect(r).toEqual({ code: 'something_else', step: null, field: null, message: 'server.generic', detail: 'penjelasan' });
    expect(m('network')).toBe('null/null:server.network');
  });
});
