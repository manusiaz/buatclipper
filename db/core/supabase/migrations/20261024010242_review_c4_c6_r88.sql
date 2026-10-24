SET local check_function_bodies = off;

ALTER TABLE "ops"."notifications"
  DROP CONSTRAINT "notifications_user_id_fkey";

CREATE OR REPLACE FUNCTION api.bridge_close_account (
  p_user uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pr market.profiles;
begin
  select * into pr from market.profiles p where p.id = p_user for update;
  if not found then
    -- belum onboarding atau replika profil dari creator belum tiba: nisan closed (replika telat hanya mengisi kolom isi, status
    -- tetap closed) dan isi di creator tetap dianonimkan.
    insert into market.profiles (id, username, display_name, status)
    values (p_user, 'deleted_' || substr(md5(p_user::text), 1, 22), 'Akun dihapus', 'closed')
    on conflict (id) do update set status = 'closed', referral_code = null, suspended_until = null;
    perform bus.emit('creator', 'profile.anonymize', jsonb_build_object('user_id', p_user));
    return jsonb_build_object('ok', true, 'reason', 'no_profile');
  end if;
  if pr.status = 'closed' then
    return jsonb_build_object('ok', true, 'reason', 'already_closed');
  end if;
  if exists (select 1 from finance.ledger_accounts a join finance.ledger_entries e on e.account_id = a.id
             where a.owner_type = 'user_wallet' and a.owner_id = p_user and e.state in ('pending', 'available')
             group by a.id, e.state having sum(e.amount) <> 0) then
    return jsonb_build_object('ok', false, 'reason', 'balance_remaining');
  end if;
  if exists (select 1 from finance.payouts p where p.user_id = p_user and p.status in ('requested', 'on_hold', 'processing', 'failed')) then
    return jsonb_build_object('ok', false, 'reason', 'payout_in_progress');
  end if;
  if exists (select 1 from finance.fulfillments f where f.user_id = p_user and f.status in ('requested', 'on_hold', 'processing', 'failed')) then
    return jsonb_build_object('ok', false, 'reason', 'fulfillment_in_progress');
  end if;

  update tracking.submissions set status = 'forfeited', next_poll_at = null where user_id = p_user and status in ('tracking', 'flagged');
  update tracking.submissions set status = 'rejected' where user_id = p_user and status in ('validating', 'in_review');
  update tracking.submissions set status = 'rejected_final' where user_id = p_user and status = 'appealed';
  update market.claims set status = 'released' where user_id = p_user and status = 'open';
  update market.profiles set referral_code = null, suspended_until = null, status = 'closed' where id = p_user;
  -- isi profil, token & akun sosmed milik creator (anonimkan, hapus token, putus akun)
  perform bus.emit('creator', 'profile.anonymize', jsonb_build_object('user_id', p_user));
  return jsonb_build_object('ok', true, 'reason', null);
end $function$;

CREATE OR REPLACE FUNCTION api.bus_receive (
  p_source text,
  p_events jsonb
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  e jsonb;
  h regprocedure;
  applied int := 0;
  skipped int := 0;
begin
  if jsonb_typeof(p_events) is distinct from 'array' then
    raise exception 'invalid:events' using errcode = 'P0001';
  end if;
  for e in select x from jsonb_array_elements(p_events) x loop
    -- klaim event dulu: kiriman kembar yang berjalan bersamaan (relay mengulang saat request pertama masih di DB) menunggu
    -- transaksi pertama lalu dilewati, bukan gagal duplicate key → 500 → backoff. Handler raise → klaim ikut batal.
    insert into bus.inbox (id, source, topic) values ((e ->> 'id')::uuid, p_source, e ->> 'topic') on conflict (id) do nothing;
    if not found then
      skipped := skipped + 1;
      continue;
    end if;
    if e ->> 'topic' = 'rep.row' then  -- replikasi baris: handler bawaan, dibatasi allowlist pengirim (bus.accepts)
      perform bus.apply_row(e -> 'payload', p_source);
      applied := applied + 1;
      continue;
    end if;
    -- topik hanya dari pengirim yang memang memanggil bus.emit-nya (bus.accepts_topic); uji.ping = handler e2e/bus.sh yang
    -- hanya ada selama uji berjalan
    if not bus.accepts_topic(p_source, e ->> 'topic') and e ->> 'topic' <> 'uji.ping' then
      raise exception 'bus_not_allowed:% %', p_source, e ->> 'topic' using errcode = '42501';
    end if;
    h := to_regprocedure(format('bus_in.%s(jsonb)', replace(e ->> 'topic', '.', '_')));
    if h is null then
      raise exception 'bus_no_handler:%', e ->> 'topic' using errcode = 'P0001';
    end if;
    execute format('select %s($1)', h::regproc)  -- pengirim bus.ping = pengirim yang terautentikasi, bukan isi payload
      using case when e ->> 'topic' = 'bus.ping' then e -> 'payload' || jsonb_build_object('source', p_source) else e -> 'payload' end;
    applied := applied + 1;
  end loop;
  return jsonb_build_object('applied', applied, 'skipped', skipped);
end $function$;

CREATE OR REPLACE FUNCTION bus.accepts_topic (
  p_source text,
  p_topic  text
)
  RETURNS boolean
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  select (p_source, p_topic) in (
    ('brand', 'audit.log'),
    ('brand', 'bus.ping'),
    ('brand', 'notify.user'),
    ('brand', 'org.owner_lost'),
    ('brand', 'review.decision'),
    ('creator', 'bus.ping'),
    ('creator', 'notify.user'),
    ('creator', 'referral.record'),
    ('creator', 'submission.post_gone')
  );
$function$;

REVOKE ALL ON FUNCTION "bus"."accepts_topic"(text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."accepts_topic"(text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."accepts_topic"(text, text) TO "postgres";
