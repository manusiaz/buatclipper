SET local check_function_bodies = off;

DROP VIEW "api"."invoices";

ALTER TABLE "finance"."invoices"
  ADD COLUMN "faktur_path" text;

CREATE OR REPLACE FUNCTION api.attach_faktur (
  p_invoice   uuid,
  p_faktur_no text,
  p_path      text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  inv finance.invoices;
  no text := btrim(coalesce(p_faktur_no, ''));
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into inv from finance.invoices i where i.id = p_invoice for update;
  if not found then
    raise exception 'not_found:invoice' using errcode = 'P0002';
  end if;
  if inv.status <> 'paid' then
    raise exception 'invalid_state:%', inv.status using errcode = 'P0001';
  end if;
  if no !~ '^[0-9][0-9.-]{11,24}$' then
    raise exception 'invalid:faktur_no' using errcode = 'P0001';
  end if;
  if exists (select 1 from finance.invoices i where i.faktur_no = no and i.id <> inv.id) then
    raise exception 'faktur_used' using errcode = 'P0001';
  end if;
  if p_path is null or p_path not like inv.org_id || '/' || inv.id || '/%'
     or not exists (select 1 from storage.objects o where o.bucket_id = 'invoice-docs' and o.name = p_path) then
    raise exception 'file_missing' using errcode = 'P0001';
  end if;
  update finance.invoices set faktur_no = no, faktur_path = p_path where id = inv.id;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'invoice.faktur', 'invoice:' || inv.id, jsonb_build_object('faktur_no', inv.faktur_no, 'path', inv.faktur_path),
          jsonb_build_object('faktur_no', no, 'path', p_path));
end $function$;

CREATE VIEW "api"."invoices" WITH (security_invoker=true) AS  SELECT id,
    number,
    org_id,
    campaign_id,
    kind,
    subtotal,
    mgmt_fee,
    admin_fee,
    service_fee,
    tax,
    total,
    status,
    payment_channel,
    paid_amount,
    paid_at,
    faktur_no,
    faktur_path,
    issued_at,
    due_at,
    pin_until,
    pool_topups,
    credit_applied,
    fee_exempt,
    (total - credit_applied) AS amount_due
   FROM finance.invoices;

CREATE POLICY "invoice_docs_read" ON "storage"."objects"
  FOR SELECT
  TO "authenticated"
  USING
    (((bucket_id = 'invoice-docs'::text) AND (( SELECT ops.is_org_member(((storage.foldername(objects.name))[1])::uuid, VARIADIC ARRAY['brand_owner'::market.org_role,
    'brand_finance'::market.org_role]) AS is_org_member) OR ( SELECT ops.has_admin(VARIADIC ARRAY['admin_finance'::text]) AS has_admin))));

CREATE POLICY "invoice_docs_write" ON "storage"."objects"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (((bucket_id = 'invoice-docs'::text) AND ( SELECT ops.has_admin(VARIADIC ARRAY['admin_finance'::text]) AS has_admin)));

REVOKE ALL ON FUNCTION "api"."attach_faktur"(uuid, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION "api"."attach_faktur"(uuid, text, text) TO "authenticated";

REVOKE ALL ON FUNCTION "api"."attach_faktur"(uuid, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "api"."attach_faktur"(uuid, text, text) TO "postgres";

GRANT SELECT ON TABLE "api"."invoices" TO "authenticated";
