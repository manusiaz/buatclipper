-- Campaign milik brand: isi (F-B02 langkah brief/syarat/aset), duplikat isi (F-B10), undangan (F-B11). Jadwal, pool, rule, fee,
-- pengajuan + invoice ada di api.save_campaign project admin (builder memanggil keduanya). Kode error: kepala ops/_base.sql.

-- F-B02/F-A03 isi campaign. p_campaign: {id?, org_id (wajib saat buat), kolom isi..., assets: [{kind, storage_path | url,
-- size_bytes?, audience?}] (daftar lengkap: yang tidak ada dihapus)}. Sejak diajukan (status replika admin ≠ draft/rejected) hanya
-- faq. Mengembalikan {id, content_version}: versi ini yang diteruskan builder ke admin (pengajuan menunggu replika versi itu).
create function api.save_campaign(p_campaign jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  p jsonb := coalesce(p_campaign, '{}');
  is_admin boolean := ops.has_admin('admin_ops');
  cols constant text[] := array['title', 'slug', 'type', 'category_id', 'platforms', 'brief', 'managed_brief', 'required_hashtags',
    'required_mentions', 'required_links', 'sponsored_label', 'min_duration_sec', 'max_duration_sec', 'dos', 'donts', 'example_urls',
    'faq', 'service_mode', 'review_mode', 'min_followers', 'min_account_age_days', 'min_trust_score', 'kyc_required', 'min_views',
    'max_clips_per_clipper', 'clipper_quota', 'allow_video_reuse', 'visibility', 'is_template'];
  c market.campaigns;
  org market.organizations;
  patch jsonb := '{}';
  k text;
  present text[];
  e jsonb;
  kept_assets uuid[] := '{}';
  prefix text;
  aid uuid;
  a_path text;
  a_url text;
  n_new int := 0;
  n_del int := 0;
begin
  if jsonb_typeof(p) <> 'object' then
    perform market.fail('invalid:payload', 'p_campaign harus object');
  end if;
  for k in select jsonb_object_keys(p) loop
    if not (k = any (cols) or k in ('id', 'org_id', 'assets')) then
      perform market.fail('invalid:unknown_key', k);
    end if;
  end loop;
  if p ? 'id' then
    select * into c from market.campaigns where id = (p ->> 'id')::uuid for update;
    if c.id is null then
      perform market.fail('not_found:campaign', null, 'P0002');
    end if;
    if p ? 'org_id' and (p ->> 'org_id')::uuid is distinct from c.org_id then
      perform market.fail('invalid:org_id', 'campaign tidak bisa pindah org');
    end if;
  end if;
  select * into org from market.organizations where id = coalesce(c.org_id, (p ->> 'org_id')::uuid);
  if org.id is null then
    perform market.fail('not_found:org', null, 'P0002');
  end if;
  if not (ops.is_org_member(org.id, 'brand_owner', 'brand_manager') or is_admin) then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org atau admin_ops aal2', '42501');
  end if;
  if org.status = 'suspended' then
    perform market.fail('org_suspended', 'org disuspend');
  end if;
  if is_admin then  -- F-A11: builder admin (paket managed) tercatat
    insert into ops.audit_logs (actor_id, action, target, before, after)
    values (uid, 'campaign.save', 'campaign:' || coalesce(p ->> 'id', 'new'), jsonb_build_object('status', c.status),
            jsonb_build_object('keys', (select jsonb_agg(k2 order by k2) from jsonb_object_keys(p) k2)));
  end if;

  -- Sejak diajukan brief terkunci (trigger campaigns_content_guard); di sini hanya FAQ yang diterima.
  if c.id is not null and c.status not in ('draft', 'rejected') then
    if exists (select 1 from jsonb_object_keys(p) x where x not in ('id', 'org_id', 'faq')) then
      perform market.fail('campaign_locked', format('campaign %s: yang bisa diubah hanya faq', c.status));
    end if;
    if p ? 'faq' then
      update market.campaigns set faq = p -> 'faq' where id = c.id returning * into c;
    end if;
    return jsonb_build_object('id', c.id, 'content_version', c.content_version);
  end if;

  for k in select x from jsonb_object_keys(p) x where x = any (cols) loop
    patch := patch || jsonb_build_object(k, p -> k);
  end loop;
  if patch ? 'title' then
    patch := patch || jsonb_build_object('title', btrim(patch ->> 'title'));
  end if;
  if patch ? 'required_hashtags' then
    patch := patch || jsonb_build_object('required_hashtags', market.norm_list(p -> 'required_hashtags', 'hashtag', 'required_hashtags'));
  end if;
  if patch ? 'required_mentions' then
    patch := patch || jsonb_build_object('required_mentions', market.norm_list(p -> 'required_mentions', 'mention', 'required_mentions'));
  end if;
  if patch ? 'required_links' then
    patch := patch || jsonb_build_object('required_links', market.norm_list(p -> 'required_links', 'link', 'required_links'));
  end if;
  if patch ? 'example_urls' then
    patch := patch || jsonb_build_object('example_urls', market.norm_list(p -> 'example_urls', 'link', 'example_urls'));
  end if;
  if patch ? 'dos' then
    patch := patch || jsonb_build_object('dos', market.norm_list(p -> 'dos', 'text', 'dos'));
  end if;
  if patch ? 'donts' then
    patch := patch || jsonb_build_object('donts', market.norm_list(p -> 'donts', 'text', 'donts'));
  end if;
  if patch ? 'slug' then
    patch := patch || jsonb_build_object('slug', lower(btrim(patch ->> 'slug')));
    if (patch ->> 'slug') !~ '^[a-z0-9-]{3,80}$' then
      perform market.fail('invalid:slug', 'slug 3–80 huruf kecil, angka, -');
    end if;
  elsif c.id is null then
    patch := patch || jsonb_build_object('slug',
      left(coalesce(nullif(btrim(regexp_replace(lower(coalesce(patch ->> 'title', '')), '[^a-z0-9]+', '-', 'g'), '-'), ''), 'campaign'), 60)
      || '-' || substr(md5(gen_random_uuid()::text), 1, 6));
  end if;
  if exists (select 1 from market.campaigns x where x.slug = patch ->> 'slug' and x.id is distinct from c.id) then
    perform market.fail('slug_taken', patch ->> 'slug');
  end if;

  select array_agg(x) into present from jsonb_object_keys(patch) x;
  if c.id is null then
    patch := patch || jsonb_build_object('org_id', org.id, 'created_by', uid);
    present := present || array['org_id', 'created_by'];
    execute format('insert into market.campaigns (%1$s) select %1$s from jsonb_populate_record(null::market.campaigns, $1) returning *',
                   (select string_agg(quote_ident(x), ', ') from unnest(present) x))
      using patch into c;
  elsif cardinality(present) > 0 then
    execute format('update market.campaigns t set (%1$s) = (select %1$s from jsonb_populate_record(null::market.campaigns, $1)) '
                   'where t.id = $2', (select string_agg(quote_ident(x), ', ') from unnest(present) x))
      using patch, c.id;
  end if;

  -- Aset (E-10): file wajib di folder {org}/{campaign}/ (internal/ = berkas brief mentah, hanya anggota org + admin).
  if p ? 'assets' then
    if jsonb_typeof(p -> 'assets') <> 'array' then
      perform market.fail('invalid:assets', 'assets harus array');
    end if;
    prefix := org.id::text || '/' || c.id::text || '/';
    for e in select jsonb_array_elements(p -> 'assets') loop
      a_path := nullif(btrim(e ->> 'storage_path'), '');
      a_url := (market.norm_list(case when e ? 'url' then jsonb_build_array(e -> 'url') end, 'link', 'asset_url'))[1];
      if a_path is not null and left(a_path, length(prefix)) <> prefix then
        perform market.fail('invalid:asset_path', format('file harus di folder %s', prefix));
      end if;
      select x.id into aid from market.campaign_assets x
       where x.campaign_id = c.id and (x.storage_path = a_path or x.url = a_url) limit 1;
      if aid is null then
        insert into market.campaign_assets (campaign_id, kind, storage_path, url, size_bytes, audience)
        values (c.id, e ->> 'kind', a_path, a_url, market.jnum(e -> 'size_bytes')::bigint,
                coalesce(e ->> 'audience', case when split_part(a_path, '/', 3) = 'internal' then 'internal' else 'clipper' end))
        returning id into aid;
        n_new := n_new + 1;
      end if;
      kept_assets := kept_assets || aid;
    end loop;
    delete from market.campaign_assets where campaign_id = c.id and not (id = any (kept_assets));
    get diagnostics n_del = row_count;
    -- aset = isi: versi naik supaya admin (gerbang versi) baru menerima setelah replika aset tiba
    if n_new + n_del > 0 then
      update market.campaigns set content_version = content_version + 1 where id = c.id;
    end if;
  end if;
  select * into c from market.campaigns where id = c.id;
  return jsonb_build_object('id', c.id, 'content_version', c.content_version);
end $$;

-- F-B10: salinan isi selalu draft (tanpa jadwal, pin, aset). Pool & rule disalin di admin (api.copy_campaign_economics).
create function api.duplicate_campaign(p_campaign uuid, p_as_template boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  nid uuid := gen_random_uuid();
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  insert into market.campaigns (id, org_id, slug, title, type, category_id, platforms, brief, required_hashtags, required_mentions,
                                required_links, sponsored_label, min_duration_sec, max_duration_sec, dos, donts, example_urls, faq,
                                review_mode, min_followers, min_account_age_days, min_trust_score, kyc_required,
                                min_views, max_clips_per_clipper, clipper_quota, allow_video_reuse, visibility, is_template, created_by)
  values (nid, c.org_id, left(regexp_replace(c.slug, '-[0-9a-f]{6}$', ''), 72) || '-' || substr(md5(nid::text), 1, 6),
          c.title, c.type, c.category_id, c.platforms, c.brief, c.required_hashtags, c.required_mentions, c.required_links,
          c.sponsored_label, c.min_duration_sec, c.max_duration_sec, c.dos, c.donts, c.example_urls, c.faq,
          c.review_mode, c.min_followers, c.min_account_age_days, c.min_trust_score, c.kyc_required, c.min_views,
          c.max_clips_per_clipper, c.clipper_quota, c.allow_video_reuse, c.visibility, coalesce(p_as_template, false), uid);
  return nid;
end $$;

-- F-B11: undang clipper (username) ke campaign; campaign visibility invite hanya terlihat yang diundang (RLS).
-- Mengembalikan jumlah undangan baru; tiap undangan baru → notifikasi campaign.invited (rate per 1.000 views diisi admin).
create function api.invite_to_campaign(p_campaign uuid, p_usernames text[]) returns int
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  c market.campaigns;
  pr record;
  n int := 0;
  k int;
begin
  select * into c from market.campaigns where id = p_campaign;
  if c.id is null then
    perform market.fail('not_found:campaign', null, 'P0002');
  end if;
  if not ops.is_org_member(c.org_id, 'brand_owner', 'brand_manager') then
    perform market.fail('auth:forbidden', 'butuh brand_owner/brand_manager org', '42501');
  end if;
  if c.is_template or c.status in ('cancelled', 'rejected', 'settling', 'settled') then
    perform market.fail('invalid_state:' || c.status, 'campaign ini tidak bisa menerima undangan');
  end if;
  if coalesce(cardinality(p_usernames), 0) > 500 then
    perform market.fail('invalid:usernames', 'maks 500 username per panggilan');
  end if;
  for pr in select p.id from market.profiles p
             where p.status = 'active'
               and p.username in (select lower(btrim(ltrim(btrim(u), '@'))) from unnest(p_usernames) u) loop
    insert into market.campaign_invites (campaign_id, user_id, invited_by) values (c.id, pr.id, uid) on conflict do nothing;
    get diagnostics k = row_count;
    if k > 0 then
      n := n + 1;
      perform ops.enqueue_notification(pr.id, 'campaign.invited',
                                       jsonb_build_object('campaign_id', c.id, 'campaign_title', c.title, 'campaign_slug', c.slug,
                                                          'org_id', c.org_id,
                                                          'org_name', (select o.name from market.organizations o where o.id = c.org_id)));
    end if;
  end loop;
  return n;
end $$;

revoke execute on function api.save_campaign(jsonb), api.duplicate_campaign(uuid, boolean), api.invite_to_campaign(uuid, text[]) from public;
grant execute on function api.save_campaign(jsonb), api.duplicate_campaign(uuid, boolean), api.invite_to_campaign(uuid, text[]) to authenticated;
