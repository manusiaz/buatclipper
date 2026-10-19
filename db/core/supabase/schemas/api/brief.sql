-- Cek caption terhadap brief (F-C06, §11): mengembalikan yang kurang, mis. {'#mplid','@studiosatu','https://studio.id/promo'};
-- '{}' = lengkap; NULL = campaign tidak terlihat oleh pemanggil. Dipakai Edge Function core/social saat submit, core/track-worker
-- tiap snapshot (caption diedit → flag), dan app clipper untuk cek sebelum submit. Hashtag & mention tidak peka huruf besar;
-- link cukup muncul tanpa https:// dan www. Security invoker lewat api.campaigns, jadi RLS campaign tetap berlaku.
create function api.missing_brief_tags(p_campaign uuid, p_caption text) returns text[]
language plpgsql stable set search_path = '' as $$
declare
  c record;
  cap text := lower(coalesce(p_caption, ''));
  tags text[];
  handles text[];
  missing text[] := '{}';
  x text;
begin
  select required_hashtags, required_mentions, required_links into c from api.campaigns where id = p_campaign;
  if not found then
    return null;
  end if;
  select coalesce(array_agg(m[1]), '{}') into tags from regexp_matches(cap, '#([[:alnum:]_]+)', 'g') m;
  select coalesce(array_agg(rtrim(m[1], '.')), '{}') into handles from regexp_matches(cap, '@([[:alnum:]_.]+)', 'g') m;
  foreach x in array c.required_hashtags loop
    if not (x = any (tags)) then
      missing := missing || ('#' || x);
    end if;
  end loop;
  foreach x in array c.required_mentions loop
    if not (x = any (handles)) then
      missing := missing || ('@' || x);
    end if;
  end loop;
  foreach x in array c.required_links loop
    if position(lower(regexp_replace(regexp_replace(x, '^https://(www\.)?', ''), '/+$', '')) in cap) = 0 then
      missing := missing || x;
    end if;
  end loop;
  return missing;
end $$;
revoke execute on function api.missing_brief_tags(uuid, text) from public, anon;
grant execute on function api.missing_brief_tags(uuid, text) to authenticated, service_role;
