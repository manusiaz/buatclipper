SET local check_function_bodies = off;

CREATE OR REPLACE FUNCTION api.mark_fulfillment_delivered (
  p_fulfillment uuid,
  p_ref         text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  f finance.fulfillments;
begin
  if not ops.has_admin('admin_ops') then
    perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
  end if;
  select * into f from finance.fulfillments x where x.id = p_fulfillment for update;
  if f.id is null then
    perform market.fail('not_found:fulfillment', null, 'P0002');
  end if;
  if f.status = 'delivered' then
    return;
  end if;
  -- webhook hanya saat macet (on_hold setelah 12× gagal) dan brand mengonfirmasi sudah mengirim di luar sistem (J-A5);
  -- pool kode tidak pernah: kode diunggah lalu worker melanjutkan sendiri.
  if not exists (select 1 from market.reward_types rt where rt.id = f.reward_type_id
                   and (rt.fulfillment = 'manual_export' or (rt.fulfillment = 'webhook' and f.status = 'on_hold'))) then
    perform market.fail('invalid:fulfillment', 'reward otomatis ditandai manual hanya webhook yang macet');
  end if;
  if f.status not in ('requested', 'on_hold', 'processing') then
    perform market.fail('invalid_state:' || f.status);
  end if;
  if nullif(btrim(p_ref), '') is null then
    perform market.fail('invalid:ref', 'referensi kiriman wajib');
  end if;
  perform api.worker_fulfillment_result(f.id, true, left(btrim(p_ref), 200), null);
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'fulfillment.deliver', 'fulfillment:' || f.id, jsonb_build_object('status', f.status),
          jsonb_build_object('status', 'delivered', 'ref', left(btrim(p_ref), 200)));
end $function$;

CREATE OR REPLACE FUNCTION api.retry_fulfillment (
  p_fulfillment uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  uid uuid := market.session_uid();
  f finance.fulfillments;
begin
  if not ops.has_admin('admin_ops') then
    perform market.fail('auth:forbidden', 'butuh admin_ops aal2', '42501');
  end if;
  select * into f from finance.fulfillments x where x.id = p_fulfillment for update;
  if f.id is null then
    perform market.fail('not_found:fulfillment', null, 'P0002');
  end if;
  if f.status <> 'on_hold' or (select rt.fulfillment from market.reward_types rt where rt.id = f.reward_type_id) <> 'webhook' then
    perform market.fail('invalid_state:' || f.status, 'hanya webhook yang macet');
  end if;
  update finance.fulfillments set attempts = 0, next_retry_at = now() where id = f.id;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'fulfillment.retry', 'fulfillment:' || f.id, jsonb_build_object('attempts', f.attempts, 'last_error', f.last_error),
          jsonb_build_object('attempts', 0));
end $function$;

CREATE OR REPLACE FUNCTION api.worker_fulfillment_result (
  p_fulfillment uuid,
  p_ok          boolean,
  p_ref         text,
  p_error       text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  f finance.fulfillments;
begin
  select * into f from finance.fulfillments x where x.id = p_fulfillment for update;
  if not found then
    raise exception 'not_found:fulfillment' using errcode = 'P0002';
  end if;
  if f.status = 'delivered' then
    return;
  end if;
  if p_ok then
    if f.status in ('requested', 'on_hold') then
      update finance.fulfillments set status = 'processing' where id = f.id;
    end if;
    update finance.fulfillments set status = 'delivered', delivered_ref = p_ref, delivered_at = now(), last_error = null,
           next_retry_at = null, leased_until = null
     where id = f.id;
    perform ops.enqueue_notification(f.user_id, 'fulfillment.delivered', finance.amount_ref(f.reward_type_id, f.amount)
                                     || jsonb_build_object('fulfillment_id', f.id, 'reward_type_id', f.reward_type_id,
                                                           'reward_name', (select rt.name from market.reward_types rt where rt.id = f.reward_type_id)));
  else
    -- 4xx = brand menolak dengan jelas; selain itu (timeout, network_error, 5xx) reward mungkin sudah diproses brand.
    update finance.fulfillments set attempts = attempts + 1, last_error = left(p_error, 500), next_retry_at = now() + interval '5 minutes',
           leased_until = null, delivery_uncertain = delivery_uncertain or coalesce(p_error, '') !~ '^http_4[0-9][0-9]$'
     where id = f.id;
    if f.attempts + 1 >= 12 and f.status in ('requested', 'on_hold') then
      update finance.fulfillments set status = 'on_hold', next_retry_at = null where id = f.id;
      perform ops.raise_alert('fulfillment.stuck', 'warning',
                              jsonb_build_object('fulfillment_id', f.id, 'attempts', f.attempts + 1, 'error', left(p_error, 500)));
    end if;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION api.worker_fulfillments_due (
  p_limit integer
)
  RETURNS TABLE (
    id             uuid,
    user_id        uuid,
    reward_type_id uuid,
    amount         numeric,
    recipient      jsonb,
    fulfillment    text,
    webhook_url    text,
    webhook_secret text,
    attempts       smallint
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
#variable_conflict use_column
begin
  return query
  with due as (
    select f.id as fid from finance.fulfillments f join market.reward_types rt on rt.id = f.reward_type_id
     where (f.status = 'requested'
            -- pool kode sempat kosong: lanjut otomatis begitu ada kode bebas lagi (S-06 on_hold → processing)
            -- (atau kodenya sudah terpasang tapi hasil kirim belum tercatat: worker mati di tengah jalan)
            or (f.status = 'on_hold' and f.last_error = 'code_pool_empty' and rt.fulfillment = 'code_pool'
                and exists (select 1 from finance.reward_codes rc where rc.reward_type_id = f.reward_type_id
                             and (rc.fulfillment_id is null or rc.fulfillment_id = f.id)))
            -- webhook macet yang dikirim ulang admin (api.retry_fulfillment: next_retry_at terisi lagi)
            or (f.status = 'on_hold' and rt.fulfillment = 'webhook' and f.next_retry_at is not null))
       and rt.fulfillment in ('code_pool', 'webhook')
       and (f.next_retry_at is null or f.next_retry_at <= now())
     order by coalesce(f.next_retry_at, f.created_at), f.id
     limit greatest(coalesce(p_limit, 20), 1)
     for update of f skip locked),
  upd as (
    -- Lease lama masih terisi = worker sebelumnya mati sebelum mencatat hasil: kiriman itu mungkin sudah sampai ke brand.
    update finance.fulfillments f set next_retry_at = now() + interval '5 minutes', leased_until = now() + interval '5 minutes',
           delivery_uncertain = f.delivery_uncertain or f.leased_until is not null
      from due where f.id = due.fid
    returning f.id as fid, f.user_id as uid, f.reward_type_id as rtid, f.amount as amt, f.recipient as rcp, f.attempts as att)
  select upd.fid, upd.uid, upd.rtid, upd.amt::numeric, upd.rcp, rt.fulfillment, rt.webhook_url,
         (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.id = rt.webhook_secret_ref), upd.att
    from upd join market.reward_types rt on rt.id = upd.rtid;
end $function$;

REVOKE ALL ON FUNCTION "api"."retry_fulfillment"(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."retry_fulfillment"(uuid) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."retry_fulfillment"(uuid) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."retry_fulfillment"(uuid) TO "postgres";
