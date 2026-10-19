-- Seed E2E: org terverifikasi + campaign tayang (TikTok, pool Rp5 jt, Rp2.000/1.000 views). Idempoten lewat id tetap.
\set ON_ERROR_STOP 1
begin;
insert into market.profiles (id, username, display_name) values ('e2e00000-0000-0000-0000-0000000000b0', 'e2e_brand_owner', 'E2E Owner')
  on conflict do nothing;
insert into market.organizations (id, name, org_type, legal_name, npwp, address, status, verified_by, verified_at, created_by)
values ('e2e00000-0000-0000-0000-0000000000a0', 'E2E Studio', 'badan', 'PT E2E Studio', '0123456789012777', 'Jakarta', 'verified',
        'e2e00000-0000-0000-0000-0000000000b0', now(), 'e2e00000-0000-0000-0000-0000000000b0') on conflict do nothing;
insert into market.org_members (org_id, user_id, role) values
  ('e2e00000-0000-0000-0000-0000000000a0', 'e2e00000-0000-0000-0000-0000000000b0', 'brand_owner') on conflict do nothing;
do $$
begin
  if not exists (select 1 from market.campaigns where id = 'e2e00000-0000-0000-0000-0000000000c0') then
    insert into market.campaigns (id, org_id, slug, title, type, category_id, platforms, required_hashtags, brief, start_at, submit_deadline,
                                  review_mode, visibility, created_by)
    values ('e2e00000-0000-0000-0000-0000000000c0', 'e2e00000-0000-0000-0000-0000000000a0', 'e2e-journey', 'E2E Journey Campaign',
            'clipping', 'games', '{tiktok}', '{e2eclipper}', '**Brief** E2E', now() - interval '1 day', now() + interval '14 days',
            'manual', 'public', 'e2e00000-0000-0000-0000-0000000000b0');
    insert into finance.reward_pools (id, campaign_id, reward_type_id, total, allocated, max_per_clip)
    values ('e2e00000-0000-0000-0000-0000000000d0', 'e2e00000-0000-0000-0000-0000000000c0', finance.idr(), 5000000, 0, 500000);
    insert into market.rate_rules (campaign_id, kind, reward_type_id, pool_id, params)
    values ('e2e00000-0000-0000-0000-0000000000c0', 'per_1k_views', finance.idr(), 'e2e00000-0000-0000-0000-0000000000d0', '{"rate": 2000}');
    update market.campaigns set status = 'in_review' where id = 'e2e00000-0000-0000-0000-0000000000c0';
    update market.campaigns set status = 'scheduled' where id = 'e2e00000-0000-0000-0000-0000000000c0';
    update market.campaigns set status = 'live' where id = 'e2e00000-0000-0000-0000-0000000000c0';
  end if;
end $$;
commit;
