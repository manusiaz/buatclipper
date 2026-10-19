SET local check_function_bodies = off;

DROP FUNCTION "api"."bridge_attach_export"(uuid, text, jsonb);

DROP FUNCTION "api"."cancel_fulfillment"(uuid, text);

ALTER TABLE "finance"."fulfillments"
  ADD COLUMN "delivery_uncertain" boolean NOT NULL DEFAULT false;

ALTER TABLE "finance"."fulfillments"
  ADD COLUMN "export_ref" text;

CREATE OR REPLACE FUNCTION api.bridge_attach_export (
  p_batch    uuid,
  p_file_ref text,
  p_held     jsonb,
  p_exported uuid[]
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  b finance.payout_batches;
  x record;
begin
  select * into b from finance.payout_batches pb where pb.id = p_batch for update;
  if not found then
    raise exception 'not_found:batch' using errcode = 'P0002';
  end if;
  if b.status = 'exported' and b.file_ref = p_file_ref then
    return;
  end if;
  if b.status <> 'approved' then
    raise exception 'invalid_state:%', b.status using errcode = 'P0001';
  end if;
  if p_file_ref is null or btrim(p_file_ref) = '' then
    raise exception 'invalid:file_ref' using errcode = 'P0001';
  end if;
  perform 1 from finance.payouts p where p.batch_id = b.id order by p.id for update;
  if exists (select 1 from unnest(coalesce(p_exported, '{}')) e(id)
              where not exists (select 1 from finance.payouts p where p.id = e.id and p.batch_id = b.id and p.status = 'requested'))
     or exists (select 1 from finance.payouts p where p.batch_id = b.id and p.status = 'requested'
                   and p.id <> all (coalesce(p_exported, '{}'))
                   and p.id not in (select h.payout_id from jsonb_to_recordset(coalesce(p_held, '[]')) h(payout_id uuid))) then
    raise exception 'export_stale' using errcode = 'P0001', detail = 'isi batch berubah sejak dibaca; ekspor ulang';
  end if;
  for x in select * from jsonb_to_recordset(coalesce(p_held, '[]')) h(payout_id uuid, reason text) loop
    update finance.payouts set status = 'on_hold', hold_reason = coalesce(nullif(btrim(x.reason), ''), 'export_check_failed')
     where id = x.payout_id and batch_id = b.id and status = 'requested';
    if found then
      perform ops.raise_alert('payout.on_hold', 'warning', jsonb_build_object('payout_id', x.payout_id, 'batch_id', b.id,
                                                                                'reason', x.reason));
    end if;
  end loop;
  update finance.payouts set status = 'processing' where batch_id = b.id and status = 'requested';
  update finance.payout_batches pb set status = 'exported', file_ref = p_file_ref,
         count = (select count(*) from finance.payouts p where p.batch_id = b.id and p.status = 'processing'),
         total = coalesce((select sum(p.amount - p.fee) from finance.payouts p where p.batch_id = b.id and p.status = 'processing'), 0)
   where pb.id = b.id;
end $function$;

CREATE OR REPLACE FUNCTION api.bridge_attach_fulfillment_export (
  p_reward_type uuid,
  p_file_ref    text,
  p_exported    uuid[]
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
begin
  if p_file_ref is null or btrim(p_file_ref) = '' then
    raise exception 'invalid:file_ref' using errcode = 'P0001';
  end if;
  perform 1 from finance.fulfillments f where f.id = any (coalesce(p_exported, '{}')) order by f.id for update;
  if exists (select 1 from unnest(coalesce(p_exported, '{}')) e(id)
              where not exists (select 1 from finance.fulfillments f join market.reward_types rt on rt.id = f.reward_type_id
                                 where f.id = e.id and f.reward_type_id = p_reward_type and f.status = 'requested'
                                   and rt.fulfillment = 'manual_export')) then
    raise exception 'export_stale' using errcode = 'P0001', detail = 'klaim berubah sejak dibaca; ekspor ulang';
  end if;
  update finance.fulfillments set status = 'processing', export_ref = p_file_ref where id = any (p_exported);
end $function$;

CREATE OR REPLACE FUNCTION api.cancel_fulfillment (
  p_fulfillment             uuid,
  p_reason                  text,
  p_confirmed_not_delivered boolean DEFAULT false
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  f finance.fulfillments;
  wallet uuid;
begin
  if not ops.has_admin('admin_ops', 'admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'invalid:reason' using errcode = 'P0001';
  end if;
  select * into f from finance.fulfillments x where x.id = p_fulfillment for update;
  if not found then
    raise exception 'not_found:fulfillment' using errcode = 'P0002';
  end if;
  if f.status in ('cancelled', 'returned') then
    return;
  end if;
  if f.status = 'delivered' then
    raise exception 'invalid_state:delivered' using errcode = 'P0001';
  end if;
  if exists (select 1 from finance.reward_codes rc where rc.fulfillment_id = f.id) then
    raise exception 'code_assigned' using errcode = 'P0001';
  end if;
  -- Worker sedang mengirim (webhook/kode): dana tidak dikembalikan sebelum hasil pengiriman tercatat.
  if f.leased_until > now() then
    raise exception 'delivery_in_flight' using errcode = 'P0001', detail = 'tunggu hasil pengiriman (maks 5 menit)';
  end if;
  if (f.delivery_uncertain or f.leased_until is not null or f.export_ref is not null) and not coalesce(p_confirmed_not_delivered, false) then
    raise exception 'delivery_unconfirmed' using errcode = 'P0001', detail = 'pastikan ke brand reward tidak terkirim, lalu konfirmasi';
  end if;
  if f.status = 'requested' then
    update finance.fulfillments set status = 'on_hold' where id = f.id;
  elsif f.status = 'processing' then
    update finance.fulfillments set status = 'failed' where id = f.id;
  end if;
  update finance.fulfillments set status = case when f.status in ('requested', 'on_hold') then 'cancelled' else 'returned' end
                                           ::finance.fulfillment_status,
         last_error = p_reason, next_retry_at = null
   where id = f.id;
  wallet := finance.account('user_wallet', f.user_id, f.reward_type_id);
  perform finance.post(gen_random_uuid(), jsonb_build_array(
    finance.e(wallet, -f.amount, 'fulfillment', f.id || ':return', 'withdrawn'),
    finance.e(wallet, f.amount, 'fulfillment', f.id || ':return', 'available')));
  perform ops.enqueue_notification(f.user_id, 'fulfillment.cancelled', finance.amount_ref(f.reward_type_id, f.amount)
                                   || jsonb_build_object('fulfillment_id', f.id, 'reason', p_reason));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'fulfillment.cancel', 'fulfillment:' || f.id, jsonb_build_object('status', f.status),
          jsonb_build_object('reason', p_reason, 'confirmed_not_delivered', coalesce(p_confirmed_not_delivered, false),
                             'delivery_uncertain', f.delivery_uncertain, 'export_ref', f.export_ref));
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
    if f.attempts + 1 >= 12 and f.status = 'requested' then
      update finance.fulfillments set status = 'on_hold', next_retry_at = null where id = f.id;
      perform ops.raise_alert('fulfillment.stuck', 'warning',
                              jsonb_build_object('fulfillment_id', f.id, 'attempts', f.attempts + 1, 'error', left(p_error, 500)));
    end if;
  end if;
end $function$;

REVOKE ALL ON FUNCTION "api"."bridge_attach_export"(uuid, text, jsonb, uuid[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_attach_export"(uuid, text, jsonb, uuid[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_attach_export"(uuid, text, jsonb, uuid[]) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_attach_export"(uuid, text, jsonb, uuid[]) TO "service_role";

REVOKE ALL ON FUNCTION "api"."bridge_attach_fulfillment_export"(uuid, text, uuid[]) FROM PUBLIC;

REVOKE ALL ON FUNCTION "api"."bridge_attach_fulfillment_export"(uuid, text, uuid[]) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_attach_fulfillment_export"(uuid, text, uuid[]) TO "postgres";

GRANT EXECUTE ON FUNCTION "api"."bridge_attach_fulfillment_export"(uuid, text, uuid[]) TO "service_role";

REVOKE ALL ON FUNCTION "api"."cancel_fulfillment"(uuid, text, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."cancel_fulfillment"(uuid, text, boolean) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."cancel_fulfillment"(uuid, text, boolean) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."cancel_fulfillment"(uuid, text, boolean) TO "postgres";
