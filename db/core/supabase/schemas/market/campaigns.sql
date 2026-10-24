-- E-06 campaign. Isi (judul, brief, syarat, aset, undangan) milik project brand dan tiba di sini sebagai replika (bus); kolom
-- milik admin: status (S-01, trigger di ops/state_triggers.sql), jadwal (start_at, submit_deadline, view_window_days), fee, pin,
-- submitted_version. Ditulis api.save_campaign admin (jadwal, pool, rule, pengajuan), record_review, control_campaign, job
-- lifecycle. Publik (anon) hanya melihat campaign yang sudah tayang.
create table market.campaigns (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references market.organizations (id),
  slug text not null check (slug ~ '^[a-z0-9-]{3,80}$'),
  title text not null check (char_length(title) between 3 and 120),
  type text not null check (type in ('clipping', 'ugc', 'music', 'logo', 'text')),
  category_id text references market.categories (id),
  status market.campaign_status not null default 'draft',
  platforms market.platform[] not null check (cardinality(platforms) >= 1),
  brief text not null default '',
  -- Paket managed: brief mentah dari brand (hanya anggota org & admin); `brief` = versi final susunan tim (J-A7).
  managed_brief text not null default '' check (length(managed_brief) <= 20000),
  -- Brief terstruktur (F-B02 langkah 2). Hashtag/mention disimpan huruf kecil tanpa # / @ (dinormalisasi save_campaign);
  -- hashtag, mention, dan link wajib dicek otomatis api.missing_brief_tags saat submit dan tiap snapshot (§11).
  required_hashtags text[] not null default '{}',
  required_mentions text[] not null default '{}',
  required_links text[] not null default '{}',
  sponsored_label boolean not null default true,
  min_duration_sec smallint check (min_duration_sec > 0),
  max_duration_sec smallint check (max_duration_sec > 0),
  dos text[] not null default '{}',
  donts text[] not null default '{}',
  example_urls text[] not null default '{}',
  faq jsonb not null default '[]' check (jsonb_typeof(faq) = 'array'),
  -- managed = brand minta dibantu tim (REV-3): draft berisi brief mentah + berkas internal, antre di builder admin (F-A03, J-A7).
  service_mode text not null default 'self_serve' check (service_mode in ('self_serve', 'managed')),
  start_at timestamptz,
  submit_deadline timestamptz,
  view_window_days smallint not null default 30 check (view_window_days between 1 and 90),
  review_mode text not null default 'manual' check (review_mode in ('auto', 'manual', 'brand')),
  min_followers integer not null default 0 check (min_followers >= 0),
  min_account_age_days smallint not null default 0 check (min_account_age_days >= 0),
  min_trust_score smallint not null default 0 check (min_trust_score between 0 and 100),
  kyc_required boolean not null default false,
  min_views integer not null default 1000 check (min_views >= 0),
  max_clips_per_clipper smallint not null default 10 check (max_clips_per_clipper >= 1),
  clipper_quota integer check (clipper_quota >= 1),
  allow_video_reuse boolean not null default false,
  visibility text not null default 'public' check (visibility in ('public', 'invite', 'level')),
  is_template boolean not null default false,
  fee_rule_id uuid references finance.fee_rules (id),
  pinned_until timestamptz,
  pinned_rank smallint check (pinned_rank >= 1),
  -- versi isi dari brand (naik tiap isi selain FAQ berubah) dan versi yang diajukan; isi > diajukan saat in_review = ajukan ulang
  content_version integer not null default 1,
  submitted_version integer,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  constraint campaigns_slug_unique unique (slug),
  constraint campaigns_schedule check (submit_deadline is null or start_at is null or submit_deadline > start_at),
  constraint campaigns_scheduled_has_dates check (status in ('draft', 'in_review', 'rejected', 'cancelled')
                                                  or (start_at is not null and submit_deadline is not null)),
  constraint campaigns_level_has_threshold check (visibility <> 'level' or min_trust_score > 0),
  constraint campaigns_hashtags_format check (array_position(required_hashtags, null) is null and (cardinality(required_hashtags) = 0
    or array_to_string(required_hashtags, ',') ~ '^[[:lower:][:digit:]_]+(,[[:lower:][:digit:]_]+)*$')),
  constraint campaigns_mentions_format check (array_position(required_mentions, null) is null and (cardinality(required_mentions) = 0
    or array_to_string(required_mentions, ',') ~ '^[[:lower:][:digit:]_.]+(,[[:lower:][:digit:]_.]+)*$')),
  constraint campaigns_links_https check (array_position(required_links, null) is null and (cardinality(required_links) = 0
    or array_to_string(required_links, ' ') ~ '^https://\S+( https://\S+)*$')),
  constraint campaigns_examples_https check (array_position(example_urls, null) is null and (cardinality(example_urls) = 0
    or array_to_string(example_urls, ' ') ~ '^https://\S+( https://\S+)*$')),
  constraint campaigns_duration_range check (min_duration_sec is null or max_duration_sec is null or min_duration_sec <= max_duration_sec)
);
create index campaigns_org_idx on market.campaigns (org_id);
create index campaigns_category_idx on market.campaigns (category_id);
create index campaigns_fee_rule_idx on market.campaigns (fee_rule_id);
create index campaigns_status_start_idx on market.campaigns (status, start_at);
create index campaigns_pinned_idx on market.campaigns (pinned_rank) where pinned_until is not null;
create index campaigns_managed_queue_idx on market.campaigns (created_at) where service_mode = 'managed' and status = 'draft';

-- Template tidak pernah diajukan: penjaga hanya di titik pengajuan (→ in_review, kolom milik admin). is_template milik brand dan bisa
-- tiba lewat replika sesudah campaign diajukan (replika status di brand tertinggal); transisi lain (rejected/draft oleh hook,
-- lifecycle scheduled → live) tidak boleh ikut gagal — kalau gagal, batch bus atau seluruh run_lifecycle ikut batal.
create function market.template_stays_draft() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.is_template and new.status = 'in_review' then
    raise exception 'invalid:template' using errcode = '23514', detail = 'template tidak bisa diajukan; duplikat dulu';
  end if;
  return new;
end $$;
create trigger campaigns_template_stays_draft before insert or update of status on market.campaigns
  for each row execute function market.template_stays_draft();

-- Isi yang sudah disetujui (status sesudah in_review) tidak berubah lewat replika: brand mengunci brief dari replika status yang bisa
-- tertinggal (admin → brand macet) — isi versi lebih baru dari yang diajukan dipertahankan + alert (event tidak ditolak, antrean
-- jalan). FAQ tetap boleh (sama dengan kunci brand); slug tidak dibekukan (unik lintas campaign: brand bisa memakai ulang slug lama
-- untuk campaign lain dan replikanya akan macet). Uang, fraud & syarat submisi memakai isi yang disetujui.
create function market.campaign_content_frozen() returns trigger
language plpgsql set search_path = '' as $$
declare
  frozen jsonb;
begin
  if current_setting('bus.applying', true) is distinct from 'on' or old.status in ('draft', 'in_review', 'rejected')
     or old.submitted_version is null or coalesce(new.content_version, 0) <= old.submitted_version then
    return new;
  end if;
  select jsonb_object_agg(k, to_jsonb(old) -> k) into frozen from unnest(bus.accepts('brand', 'market.campaigns')) k
   where k not in ('faq', 'slug');
  if (select jsonb_object_agg(k, to_jsonb(new) -> k) from jsonb_object_keys(frozen) k) is distinct from frozen then
    new := jsonb_populate_record(new, frozen);
    perform ops.raise_alert('campaign.content_drift', 'critical', jsonb_build_object('campaign_id', old.id, 'status', old.status));
  end if;
  return new;
end $$;
create trigger campaigns_content_frozen before update on market.campaigns
  for each row execute function market.campaign_content_frozen();

-- Status, jadwal, pin ke brand (tampilan builder/dashboard; kunci brief di brand membaca status ini). Ke creator juga tag wajib
-- caption (dicek creator saat submit, tidak bisa dicek ulang admin): versi admin = isi yang disetujui (campaign_content_frozen),
-- ikut terkirim tiap perubahan status (termasuk saat disetujui); brand tidak mengirim kolom ini ke creator.
create trigger campaigns_replicate after insert or update or delete on market.campaigns for each row
  execute function bus.replicate('brand:status,start_at,submit_deadline,view_window_days,pinned_until',
                                'creator:status,submit_deadline,view_window_days,required_hashtags,required_mentions,required_links');

-- Isi tiba dari brand (bus.apply_row). Brand mengunci brief sejak status replika ≠ draft/rejected; balapan dengan replika status
-- (isi berubah tepat setelah diajukan) ditutup di sini: in_review dengan isi lebih baru dari yang diajukan → kembali draft, invoice
-- campaign yang belum dibayar batal, brand diminta mengajukan ulang. rejected + isi baru = diperbaiki → draft. Tidak pernah raise
-- (event yang gagal menahan antrean bus): gagal → alert ops, replika isi tetap tersimpan.
create function bus_in.market_campaigns_applied(p_op text, p_row jsonb) returns void
language plpgsql set search_path = '' as $$
declare
  c market.campaigns;
begin
  if p_op <> 'upsert' then
    return;
  end if;
  select * into c from market.campaigns where id = (p_row ->> 'id')::uuid for update;
  if c.id is null or c.content_version <= coalesce(c.submitted_version, 0) then
    return;
  end if;
  if c.status = 'rejected' then
    update market.campaigns set status = 'draft' where id = c.id;
  elsif c.status = 'in_review' then
    update market.campaigns set status = 'rejected' where id = c.id;
    update market.campaigns set status = 'draft' where id = c.id;
    update finance.invoices set status = 'void' where campaign_id = c.id and kind = 'campaign' and status = 'issued';
    perform market.notify_org(c.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'campaign.rejected',
                              jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'reason', 'content_changed'));
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (null, 'campaign.resubmit_required', 'campaign:' || c.id, jsonb_build_object('submitted_version', c.submitted_version),
            jsonb_build_object('content_version', c.content_version));
  end if;  -- status sesudah disetujui: isi dibekukan (market.campaign_content_frozen), versi tidak naik
exception when others then
  perform ops.raise_alert('campaign.apply_failed', 'critical', jsonb_build_object('campaign_id', p_row ->> 'id', 'error', sqlerrm));
end $$;
revoke execute on function bus_in.market_campaigns_applied(text, jsonb) from public;

-- E-37 undangan campaign privat (F-B11). Satu file dengan campaigns karena policy baca campaign memakainya.
create table market.campaign_invites (
  campaign_id uuid not null references market.campaigns (id) on delete cascade,
  user_id uuid not null,  -- tanpa FK: replika dari brand, profilnya dari creator (urutan antar sumber tidak dijamin)
  invited_by uuid not null,
  created_at timestamptz not null default now(),
  primary key (campaign_id, user_id)
);
create index campaign_invites_user_idx on market.campaign_invites (user_id);

alter table market.campaign_invites enable row level security;
create policy campaign_invites_iss on market.campaign_invites as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy campaign_invites_own_read on market.campaign_invites for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
create policy campaign_invites_admin_read on market.campaign_invites for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on market.campaign_invites to authenticated;

-- Cek undangan lewat fungsi definer: subquery langsung ke campaign_invites memicu policy-nya, yang membaca campaigns lagi
-- (rekursi tak hingga, terbukti di tes core_access).
create function market.is_invited(p_campaign uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  return exists (select 1 from market.campaign_invites i where i.campaign_id = p_campaign and i.user_id = (select auth.uid()));
end $$;
revoke execute on function market.is_invited(uuid) from public;
grant execute on function market.is_invited(uuid) to authenticated;

alter table market.campaigns enable row level security;
create policy campaigns_iss on market.campaigns as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
-- Publik = sudah tayang dan bukan template. anon hanya visibility public; user login juga melihat campaign privat kalau
-- diundang (invite) atau Trust Score-nya cukup (level). Dua policy terpisah: subquery ke tabel yang tidak boleh dibaca anon
-- akan gagal hak akses walau kondisinya tidak terpakai.
create policy campaigns_public_anon on market.campaigns for select to anon  -- policy:core.public-read
  using (status in ('live', 'paused', 'tracking', 'exhausted', 'settling', 'settled') and not is_template and visibility = 'public');
create policy campaigns_public_auth on market.campaigns for select to authenticated  -- policy:core.public-read
  using (status in ('live', 'paused', 'tracking', 'exhausted', 'settling', 'settled') and not is_template
         and (visibility = 'public'
              or (visibility = 'invite' and market.is_invited(id))
              or (visibility = 'level' and exists (select 1 from market.profiles p
                                                   where p.id = (select auth.uid()) and p.trust_score >= campaigns.min_trust_score))));
create policy campaigns_org_read on market.campaigns for select to authenticated using ((select ops.is_org_member(org_id)));  -- policy:core.rls-org
create policy campaigns_admin_read on market.campaigns for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on market.campaigns to anon, authenticated;

-- Anggota org melihat undangan campaign org-nya (policy ini butuh tabel campaigns, jadi ditaruh setelahnya).
create policy campaign_invites_org_read on market.campaign_invites for select to authenticated  -- policy:core.rls-org
  using (exists (select 1 from market.campaigns c where c.id = campaign_id and (select ops.is_org_member(c.org_id))));
