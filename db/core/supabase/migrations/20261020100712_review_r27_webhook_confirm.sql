SET local check_function_bodies = off;

DROP VIEW "api"."fulfillments";

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
  -- webhook yang sedang dikirim worker (lease) atau sudah dijadwalkan kirim ulang belum "berhenti": konfirmasi manual bisa
  -- membuat reward terkirim dua kali (R27-1)
  if f.leased_until > now() then
    perform market.fail('delivery_in_flight', 'reward sedang dikirim worker');
  end if;
  if f.next_retry_at is not null and (select rt.fulfillment from market.reward_types rt where rt.id = f.reward_type_id) = 'webhook' then
    perform market.fail('invalid_state:retrying', 'kirim ulang terjadwal; tunggu hasilnya');
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

CREATE VIEW "api"."fulfillments" WITH (security_invoker=true) AS  SELECT id,
    user_id,
    reward_type_id,
    amount,
    recipient,
    status,
    delivered_ref,
    attempts,
    created_at,
    delivered_at,
    next_retry_at
   FROM finance.fulfillments;

GRANT SELECT ON TABLE "api"."fulfillments" TO "authenticated";
