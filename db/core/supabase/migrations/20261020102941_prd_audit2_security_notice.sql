SET local check_function_bodies = off;

DROP FUNCTION "api"."send_broadcast"(text, text, jsonb, text[], timestamp WITH time zone);

ALTER TABLE "ops"."broadcasts"
  ADD COLUMN "kind" text NOT NULL DEFAULT 'promo'::text;

CREATE OR REPLACE FUNCTION api.send_broadcast (
  p_title        text,
  p_body         text,
  p_segment      jsonb                    DEFAULT '{}'::jsonb,
  p_channels     text[]                   DEFAULT '{in_app}'::text[],
  p_scheduled_at timestamp with time zone DEFAULT NULL::timestamp WITH time zone,
  p_kind         text                     DEFAULT 'promo'::text
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  seg jsonb := coalesce(p_segment, '{}');
  k text;
  bid uuid;
begin
  if not ops.has_admin('admin_ops') then
    perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
  end if;
  if coalesce(p_kind, '') not in ('promo', 'security') then
    perform market.fail('invalid:kind', coalesce(p_kind, 'null'));
  end if;
  if p_kind = 'security' then
    if not ops.has_admin('admin_super') then
      perform market.fail('auth:forbidden', 'pemberitahuan keamanan butuh admin_super aal2', '42501');
    end if;
    if seg <> '{}' then
      perform market.fail('invalid:segment', 'pemberitahuan keamanan ke semua user');
    end if;
  end if;
  if jsonb_typeof(seg) <> 'object' then
    perform market.fail('invalid:segment', 'segmen harus object');
  end if;
  for k in select jsonb_object_keys(seg) loop
    if k not in ('platforms', 'min_trust_score', 'max_trust_score', 'kyc', 'active_days') then
      perform market.fail('invalid:segment', k);
    end if;
  end loop;
  if seg ? 'platforms' and (jsonb_typeof(seg -> 'platforms') <> 'array'
     or exists (select 1 from jsonb_array_elements_text(seg -> 'platforms') x
                where x not in (select unnest(enum_range(null::market.platform))::text))) then
    perform market.fail('invalid:segment', 'platforms');
  end if;
  if seg ? 'kyc' and seg ->> 'kyc' not in ('approved', 'not_approved') then
    perform market.fail('invalid:segment', 'kyc');
  end if;
  if (seg ? 'min_trust_score' and market.jnum(seg -> 'min_trust_score') is null)
     or (seg ? 'max_trust_score' and market.jnum(seg -> 'max_trust_score') is null)
     or (seg ? 'active_days' and coalesce(market.jnum(seg -> 'active_days'), 0) <= 0) then
    perform market.fail('invalid:segment', 'angka segmen');
  end if;
  insert into ops.broadcasts (title, body, segment, channels, created_by, scheduled_at, kind)
  values (btrim(p_title), btrim(p_body), seg,
          case when p_kind = 'security' then (select array_agg(distinct c) from unnest(coalesce(p_channels, '{}') || array['in_app', 'email']) c)
               else coalesce(p_channels, '{in_app}') end,
          uid, coalesce(p_scheduled_at, now()), p_kind)
  returning id into bid;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'broadcast.create', 'broadcast:' || bid, null,
          jsonb_build_object('title', btrim(p_title), 'segment', seg, 'channels', p_channels, 'scheduled_at', p_scheduled_at, 'kind', p_kind));
  return bid;
end $function$;

CREATE OR REPLACE FUNCTION ops.dispatch_broadcasts()
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  b ops.broadcasts;
  seg jsonb;
  r record;
  n int;
  total int := 0;
begin
  for b in select * from ops.broadcasts where sent_at is null and scheduled_at <= now()
            order by scheduled_at for update skip locked loop
    seg := b.segment;
    n := 0;
    for r in
      -- security: semua subjek data yang masih punya akun (termasuk suspend/ban), bukan hanya yang aktif
      select p.id from market.profiles p
       where (case when b.kind = 'security' then p.status <> 'closed' else p.status = 'active' end)
         and (not seg ? 'platforms'
              or exists (select 1 from tracking.social_accounts a where a.user_id = p.id and a.status = 'verified'
                         and a.platform::text in (select jsonb_array_elements_text(seg -> 'platforms'))))
         and (not seg ? 'min_trust_score' or p.trust_score >= (seg ->> 'min_trust_score')::int)
         and (not seg ? 'max_trust_score' or p.trust_score <= (seg ->> 'max_trust_score')::int)
         and (not seg ? 'kyc'
              or (seg ->> 'kyc' = 'approved') = coalesce((select d.decision = 'approve' from trust.review_decisions d
                                                          where d.target_type = 'kyc' and d.target_id = p.id
                                                          order by d.created_at desc, d.id desc limit 1), false))
         and (not seg ? 'active_days'
              or exists (select 1 from market.claims cl where cl.user_id = p.id
                         and cl.created_at >= now() - make_interval(days => (seg ->> 'active_days')::int))
              or exists (select 1 from tracking.submissions s where s.user_id = p.id
                         and s.created_at >= now() - make_interval(days => (seg ->> 'active_days')::int)))
    loop
      perform ops.enqueue_notification(r.id, case when b.kind = 'security' then 'security.notice' else 'broadcast.sent' end,
                                       jsonb_build_object('broadcast_id', b.id, 'title', b.title, 'body', b.body,
                                                          'channels', to_jsonb(b.channels)),
                                       'email' = any (b.channels) or 'push' = any (b.channels));
      n := n + 1;
    end loop;
    update ops.broadcasts set sent_at = now(), recipient_count = n where id = b.id;
    total := total + n;
  end loop;
  return total;
end $function$;

ALTER TABLE "ops"."broadcasts"
  ADD CONSTRAINT "broadcasts_kind_check" CHECK ((kind = ANY (ARRAY['promo'::text, 'security'::text])));

REVOKE ALL ON FUNCTION "api"."send_broadcast"(text, text, jsonb, text[], timestamp WITH time zone, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."send_broadcast"(text, text, jsonb, text[], timestamp WITH time zone, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."send_broadcast"(text, text, jsonb, text[], timestamp WITH time zone, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."send_broadcast"(text, text, jsonb, text[], timestamp WITH time zone, text) TO "postgres";
