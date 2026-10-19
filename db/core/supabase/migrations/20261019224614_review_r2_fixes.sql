SET local check_function_bodies = off;

ALTER TABLE "finance"."fulfillments"
  ADD COLUMN "leased_until" timestamp WITH time zone;

CREATE OR REPLACE FUNCTION api.cancel_fulfillment (
  p_fulfillment uuid,
  p_reason      text
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
          jsonb_build_object('reason', p_reason));
end $function$;

CREATE OR REPLACE FUNCTION api.cancel_payout (
  p_payout uuid,
  p_reason text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  po finance.payouts;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'invalid:reason' using errcode = 'P0001';
  end if;
  select * into po from finance.payouts p where p.id = p_payout for update;
  if not found then
    raise exception 'not_found:payout' using errcode = 'P0002';
  end if;
  if po.status = 'cancelled' then
    return;
  end if;
  if not (po.status = 'on_hold' or (po.status = 'requested' and po.channel = 'batch')) then
    raise exception 'invalid_state:%', po.status using errcode = 'P0001';
  end if;
  -- Batch approved = isi CSV transfer sedang/akan dibaca identity (get_batch → attach_export): payout requested di dalamnya
  -- tidak boleh dibatalkan, kalau tidak dananya kembali ke Tersedia sekaligus ikut ditransfer. FOR SHARE: serial dengan approve.
  if po.status = 'requested'
     and exists (select 1 from finance.payout_batches b where b.id = po.batch_id and b.status <> 'draft' for share) then
    raise exception 'batch_locked' using errcode = 'P0001',
      detail = 'batch sudah disetujui; tandai gagal setelah export bila perlu';
  end if;
  if po.status = 'requested' then
    update finance.payouts set status = 'on_hold', hold_reason = p_reason where id = po.id;
  end if;
  update finance.payouts set status = 'cancelled', hold_reason = p_reason where id = po.id;
  perform finance.unwind_payout_journal(po);
  perform ops.enqueue_notification(po.user_id, 'payout.cancelled', finance.amount_ref(finance.idr(), po.amount)
                                   || jsonb_build_object('payout_id', po.id, 'channel', po.channel, 'reason', p_reason));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout.cancel', 'payout:' || po.id, jsonb_build_object('status', po.status),
          jsonb_build_object('status', 'cancelled', 'reason', p_reason));
end $function$;

CREATE OR REPLACE FUNCTION api.worker_assign_code (
  p_fulfillment uuid
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  f finance.fulfillments;
  cid uuid;
  code text;
begin
  select * into f from finance.fulfillments x where x.id = p_fulfillment for update;
  if not found then
    raise exception 'not_found:fulfillment' using errcode = 'P0002';
  end if;
  if (select rt.fulfillment from market.reward_types rt where rt.id = f.reward_type_id) <> 'code_pool' then
    raise exception 'invalid:fulfillment_kind' using errcode = 'P0001';
  end if;
  select rc.code into code from finance.reward_codes rc where rc.fulfillment_id = f.id;
  if code is not null then
    return code;
  end if;
  if f.status <> 'requested' then
    return null;
  end if;
  select rc.id, rc.code into cid, code from finance.reward_codes rc
   where rc.reward_type_id = f.reward_type_id and rc.fulfillment_id is null
   order by rc.created_at, rc.id limit 1 for update skip locked;
  if cid is null then
    update finance.fulfillments set status = 'on_hold', last_error = 'code_pool_empty', leased_until = null where id = f.id;
    perform ops.raise_alert('fulfillment.stuck', 'warning',
                            jsonb_build_object('fulfillment_id', f.id, 'reward_type_id', f.reward_type_id, 'reason', 'code_pool_empty'));
    return null;
  end if;
  update finance.reward_codes set fulfillment_id = f.id, assigned_at = now() where id = cid;
  return code;
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
    update finance.fulfillments set attempts = attempts + 1, last_error = left(p_error, 500), next_retry_at = now() + interval '5 minutes',
           leased_until = null
     where id = f.id;
    if f.attempts + 1 >= 12 and f.status = 'requested' then
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
     where f.status = 'requested' and rt.fulfillment in ('code_pool', 'webhook')
       and (f.next_retry_at is null or f.next_retry_at <= now())
     order by coalesce(f.next_retry_at, f.created_at), f.id
     limit greatest(coalesce(p_limit, 20), 1)
     for update of f skip locked),
  upd as (
    update finance.fulfillments f set next_retry_at = now() + interval '5 minutes', leased_until = now() + interval '5 minutes'
      from due where f.id = due.fid
    returning f.id as fid, f.user_id as uid, f.reward_type_id as rtid, f.amount as amt, f.recipient as rcp, f.attempts as att)
  select upd.fid, upd.uid, upd.rtid, upd.amt::numeric, upd.rcp, rt.fulfillment, rt.webhook_url,
         (select ds.decrypted_secret from vault.decrypted_secrets ds where ds.id = rt.webhook_secret_ref), upd.att
    from upd join market.reward_types rt on rt.id = upd.rtid;
end $function$;
