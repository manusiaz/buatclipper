SET local check_function_bodies = off;

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
    raise exception 'invalid_state:batch_locked' using errcode = 'P0001',
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

CREATE OR REPLACE FUNCTION finance.correct_down (
  p_submission uuid,
  p_snapshot   bigint,
  p_views      bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  x record;
  sub record;
  total numeric;
  target numeric;
  diff numeric;
  from_demand numeric;
  from_amount numeric;
  entries jsonb := '[]';
begin
  select t.user_id, t.campaign_id, k.min_views into sub
    from tracking.submissions t join market.campaigns k on k.id = t.campaign_id where t.id = p_submission;
  perform 1 from finance.reward_pools fp where fp.campaign_id = sub.campaign_id order by fp.id for update;
  for x in select ce.*, rr.kind, rr.params, rp.reward_type_id from finance.clip_earnings ce
             join market.rate_rules rr on rr.id = ce.rule_id join finance.reward_pools rp on rp.id = ce.pool_id
            where ce.submission_id = p_submission and ce.released_at is null and ce.amount + ce.demand > 0
            order by ce.pool_id, ce.rule_id loop
    total := x.amount + x.demand;
    target := case
      when x.kind = 'flat_per_post' then total
      when x.kind = 'milestone_bonus' then
        case when p_views >= greatest(sub.min_views, (x.params ->> 'threshold')::numeric) then total else 0 end
      when p_views < sub.min_views then 0
      else least(total, trunc(finance.rule_amount(x.kind, x.params, x.views_from, least(x.views_to, p_views)), 10)) end;
    diff := total - target;
    continue when diff <= 0;
    from_demand := least(x.demand, diff);
    from_amount := diff - from_demand;
    update finance.clip_earnings ce set demand = ce.demand - from_demand, amount = ce.amount - from_amount,
           -- views turun di bawah awal rule (rule baru berlaku sejak views_from): earning rule itu hangus seluruhnya
           views_to = greatest(ce.views_from, least(ce.views_to, p_views)), updated_at = now()
     where ce.submission_id = x.submission_id and ce.rule_id = x.rule_id;
    if from_amount > 0 then
      entries := entries || jsonb_build_array(
        finance.e(finance.account('user_wallet', sub.user_id, x.reward_type_id), -from_amount, 'reversal',
                  p_snapshot || ':' || x.rule_id, 'pending'),
        finance.e(finance.account('campaign_pool', x.pool_id, x.reward_type_id), from_amount, 'reversal',
                  p_snapshot || ':' || x.rule_id));
      update finance.reward_pools set allocated = allocated - from_amount where id = x.pool_id;
    end if;
  end loop;
  perform finance.post(gen_random_uuid(), entries);
end $function$;
