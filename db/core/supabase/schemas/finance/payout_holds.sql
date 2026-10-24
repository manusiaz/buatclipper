-- Batch payout = checkpoint (§12, J-A3 A3.2): payout clipper yang diblokir tidak ikut ditransfer. Alasan blokir satu sumber:
-- profil banned/closed, suspend yang masih berlaku, flag fraud terbuka/ditahan pada profil (FR-04/FR-05: blok withdraw sampai
-- direview, sama dengan request_payout) atau pada payout itu. Flag submisi hanya ditandai di tab Payout untuk diputuskan finance.
-- Dipakai create_payout_batch, bridge_get_batch (export), sanksi, dan lepas tahan.
create function finance.payout_block(p_user uuid, p_payout uuid) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when pr.id is null then 'profile_missing'
    when pr.status in ('banned', 'closed') then 'profile_' || pr.status
    when pr.status = 'suspended' and (pr.suspended_until is null or pr.suspended_until > now()) then 'profile_suspended'
    when exists (select 1 from trust.fraud_flags f
                  where f.status in ('open', 'held')
                    and ((f.target_type = 'profile' and f.target_id = p_user) or (f.target_type = 'payout' and f.target_id = p_payout)))
      then 'fraud_flag'
  end
  from (select 1) one left join market.profiles pr on pr.id = p_user;
$$;

-- Tahan payout batch yang belum masuk CSV: requested tanpa batch atau di batch draft (S-05 requested → on_hold); batch draft
-- dihitung ulang. Batch yang sudah disetujui ditahan saat export (bridge_get_batch → identity hold).
create function finance.hold_payouts(p_user uuid, p_payout uuid, p_reason text) returns int
language plpgsql security definer set search_path = '' as $$
declare
  n int;
begin
  update finance.payouts p set status = 'on_hold', hold_reason = p_reason, batch_id = null
   where p.status = 'requested' and p.channel = 'batch' and (p_user is null or p.user_id = p_user)
     and (p_payout is null or p.id = p_payout)
     and (p.batch_id is null or exists (select 1 from finance.payout_batches b where b.id = p.batch_id and b.status = 'draft'));
  get diagnostics n = row_count;
  update finance.payout_batches b
     set count = (select count(*) from finance.payouts p where p.batch_id = b.id),
         total = coalesce((select sum(p.amount - p.fee) from finance.payouts p where p.batch_id = b.id), 0)
   where b.status = 'draft';
  return n;
end $$;

-- admin_finance: tahan payout mencurigakan tanpa mengembalikan dana (dibatalkan/dilepas setelah review).
create function api.hold_payout(p_payout uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then
    raise exception 'invalid:reason' using errcode = 'P0001';
  end if;
  if finance.hold_payouts(null, p_payout, btrim(p_reason)) = 0 then
    raise exception 'invalid_state:payout' using errcode = 'P0001',
      detail = 'hanya payout batch requested yang belum masuk batch disetujui';
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout.hold', 'payout:' || p_payout, jsonb_build_object('status', 'requested'),
          jsonb_build_object('status', 'on_hold', 'reason', btrim(p_reason)));
end $$;

-- Lepas tahan setelah review: on_hold → requested (antre batch berikutnya). Ditolak selama alasan blokir masih ada.
create function api.release_payout(p_payout uuid, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  po finance.payouts;
  blocked text;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_note, ''))) < 3 then
    raise exception 'invalid:note' using errcode = 'P0001';
  end if;
  select * into po from finance.payouts p where p.id = p_payout for update;
  if not found then
    raise exception 'not_found:payout' using errcode = 'P0002';
  end if;
  if po.status <> 'on_hold' or po.channel <> 'batch' then
    raise exception 'invalid_state:%', po.status using errcode = 'P0001';
  end if;
  blocked := finance.payout_block(po.user_id, po.id);
  if blocked is not null then
    raise exception 'payout_blocked:%', blocked using errcode = 'P0001';
  end if;
  update finance.payouts set status = 'requested', hold_reason = null, batch_id = null where id = po.id;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'payout.release', 'payout:' || po.id, jsonb_build_object('status', 'on_hold', 'reason', po.hold_reason),
          jsonb_build_object('status', 'requested', 'note', btrim(p_note)));
end $$;

revoke execute on function finance.payout_block(uuid, uuid), finance.hold_payouts(uuid, uuid, text), api.hold_payout(uuid, text),
  api.release_payout(uuid, text) from public;
grant execute on function api.hold_payout(uuid, text), api.release_payout(uuid, text) to authenticated;
