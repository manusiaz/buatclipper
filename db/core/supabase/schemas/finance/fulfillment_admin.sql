-- F-A10 tandai terkirim: reward manual_export (barang fisik/voucher yang dikirim brand di luar sistem) ditutup admin_ops (aal2)
-- dengan referensi kiriman (resi/nomor voucher). Transisi & notifikasi sama dengan worker (api.worker_fulfillment_result).
create function api.mark_fulfillment_delivered(p_fulfillment uuid, p_ref text) returns void
language plpgsql security definer set search_path = '' as $$
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
  if (select rt.fulfillment from market.reward_types rt where rt.id = f.reward_type_id) <> 'manual_export' then
    perform market.fail('invalid:fulfillment', 'hanya reward manual_export yang ditandai manual');
  end if;
  if f.status = 'delivered' then
    return;
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
end $$;
revoke execute on function api.mark_fulfillment_delivered(uuid, text) from public;
grant execute on function api.mark_fulfillment_delivered(uuid, text) to authenticated;
