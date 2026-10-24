SET local check_function_bodies = off;

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
  -- R21-1: sanksi (ban/suspend/flag) di antara get_batch dan sekarang → CSV basi ditolak; ekspor ulang menahan payout itu.
  -- Profil dikunci FOR SHARE supaya ban/suspend yang bersamaan menunggu sampai CSV ini diterima atau ditolak.
  perform 1 from market.profiles pr where pr.id in (select p.user_id from finance.payouts p where p.id = any (coalesce(p_exported, '{}')))
   order by pr.id for share;
  if exists (select 1 from finance.payouts p where p.id = any (coalesce(p_exported, '{}')) and finance.payout_block(p.user_id, p.id) is not null) then
    raise exception 'export_stale' using errcode = 'P0001', detail = 'clipper di CSV kena sanksi atau flag sejak dibaca; ekspor ulang';
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
