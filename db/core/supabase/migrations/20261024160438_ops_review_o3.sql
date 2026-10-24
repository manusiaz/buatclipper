SET local check_function_bodies = off;

CREATE TABLE "bus"."reconcile_runs" (
  "source"     text                     NOT NULL,
  "tbl"        text                     NOT NULL,
  "epoch"      uuid                     NOT NULL,
  "total"      bigint                   NOT NULL,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "reconcile_runs_pkey" PRIMARY KEY (source, tbl, epoch)
);

ALTER TABLE "bus"."reconcile_runs"
  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION api.skip_failed_snapshot (
  p_alert bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  a ops.alerts;
  v tracking.view_snapshots;
  s tracking.submissions;
begin
  if not ops.has_admin('admin_ops') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  select * into a from ops.alerts x where x.id = p_alert and x.kind = 'tracking.apply_failed' and x.resolved_at is null for update;
  if not found or coalesce(a.payload ->> 'snapshot_id', '') !~ '^[0-9]+$' then
    raise exception 'not_found:alert' using errcode = 'P0002';
  end if;
  select * into v from tracking.view_snapshots x where x.id = (a.payload ->> 'snapshot_id')::bigint;
  if not found then
    raise exception 'not_found:snapshot' using errcode = 'P0002';
  end if;
  select * into s from tracking.submissions t where t.id = v.submission_id for update;
  -- snapshot tertunda paling awal, atau final yang sudah diproses tapi accrual saat lock gagal (lifecycle step lock, O1-4)
  if v.id is distinct from (select min(x.id) from tracking.view_snapshots x
                             where x.submission_id = s.id and x.id > coalesce(s.applied_snapshot_id, 0))
     and not (v.is_final and v.id <= coalesce(s.applied_snapshot_id, 0) and s.status = 'tracking') then
    raise exception 'invalid_state:not_next_pending' using errcode = 'P0001';
  end if;
  update tracking.submissions set applied_snapshot_id = greatest(coalesce(applied_snapshot_id, 0), v.id),
         final_skipped = final_skipped or v.is_final,
         status = case when status = 'tracking' then 'flagged'::tracking.submission_status else status end
   where id = s.id;
  perform trust.raise_flag('submission', s.id, 'FR-12', 50,
                           jsonb_build_object('snapshot_id', v.id, 'alert_id', a.id, 'error', a.payload ->> 'error'));
  update ops.alerts set resolved_at = now(), resolved_by = (select auth.uid()) where id = a.id;
  -- Snapshot sesudahnya ikut gagal hanya karena menunggu yang ini: proses sekarang (berurutan), alert-nya yang sudah diproses
  -- ditutup — tidak ikut "dilewati" tanpa cek fraud/accrual (O1-C8). Masih gagal → alert-nya tetap terbuka.
  begin
    perform tracking.apply_snapshot(m) from (select max(x.id) m from tracking.view_snapshots x where x.submission_id = s.id and x.id > v.id) n
     where m is not null;
  exception when others then
    perform tracking.alert_apply_failed(s.id, null, 'skip_retry', sqlerrm);
  end;
  update ops.alerts x set resolved_at = now(), resolved_by = (select auth.uid())
   where x.kind = 'tracking.apply_failed' and x.resolved_at is null and x.payload ->> 'snapshot_id' ~ '^[0-9]+$'
     and (x.payload ->> 'snapshot_id')::bigint in (select y.id from tracking.view_snapshots y where y.submission_id = s.id
                                                    and y.id <= (select t.applied_snapshot_id from tracking.submissions t where t.id = s.id));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'snapshot.skip', 'submission:' || s.id,
          jsonb_build_object('applied_snapshot_id', s.applied_snapshot_id, 'status', s.status),
          jsonb_build_object('applied_snapshot_id', greatest(coalesce(s.applied_snapshot_id, 0), v.id), 'final_skipped', v.is_final, 'alert_id', a.id));
end $function$;

CREATE OR REPLACE FUNCTION bus.apply_keys (
  p        jsonb,
  p_source text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  t regclass := to_regclass(p ->> 'table');
begin
  if t is null then  -- penerima belum upgrade: tahan antrean (sama dengan apply_row)
    raise exception 'bus_no_table:%', p ->> 'table' using errcode = 'P0001';
  end if;
  if bus.accepts(p_source, p ->> 'table') is null then  -- bukan tabel yang direplikasi pengirim ke sini
    perform bus.reject(jsonb_build_object('reason', 'table', 'table', p ->> 'table', 'op', 'reconcile'));
    return;
  end if;
  insert into bus.reconcile_keys (source, tbl, epoch, key)
  select p_source, t::text, (p ->> 'epoch')::uuid, x from jsonb_array_elements(coalesce(p -> 'keys', '[]')) x
  on conflict do nothing;
  if not coalesce((p ->> 'last')::boolean, false) then
    return;
  end if;
  -- Daftar tidak lengkap (potongan dipangkas bus.prune saat antrean macet > 7 hari, atau dilewati bus.skip) → tidak ada yang
  -- dihapus; dilaporkan, jalankan reconcile ulang (O1-3).
  if (select count(*) from bus.reconcile_keys r where r.source = p_source and r.tbl = t::text and r.epoch = (p ->> 'epoch')::uuid)
     is distinct from (p ->> 'total')::bigint then
    perform bus.reject(jsonb_build_object('reason', 'reconcile_incomplete', 'table', t::text, 'total', p -> 'total'));
    delete from bus.reconcile_keys where source = p_source and tbl = t::text and epoch = (p ->> 'epoch')::uuid;
    return;
  end if;
  insert into bus.reconcile_runs (source, tbl, epoch, total) values (p_source, t::text, (p ->> 'epoch')::uuid, (p ->> 'total')::bigint)
  on conflict do nothing;
end $function$;

CREATE OR REPLACE FUNCTION bus.prune()
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  delete from bus.outbox where sent_at < now() - interval '14 days';
  -- rekonsiliasi yang terputus (potongan terakhir tak tiba); daftar lengkap yang masih diproses bus.reconcile_apply tidak disentuh
  delete from bus.reconcile_keys k where k.created_at < now() - interval '7 days'
     and not exists (select 1 from bus.reconcile_runs r where r.source = k.source and r.tbl = k.tbl and r.epoch = k.epoch);
$function$;

CREATE OR REPLACE FUNCTION bus.reconcile_apply (
  p_limit integer DEFAULT 5000
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r bus.reconcile_runs;
  t regclass;
  k jsonb;
  pk text[];
  n int := 0;
  budget int;
  m int;
begin
  for r in select * from bus.reconcile_runs x order by x.created_at loop
    budget := p_limit - n;
    exit when budget <= 0;
    t := to_regclass(r.tbl);
    m := 0;
    if t is not null then
      pk := bus.pk_columns(t);
      for k in execute format('select jsonb_build_object(%s) from %s x where not exists (select 1 from bus.reconcile_keys r
                                 where r.source = $1 and r.tbl = $2 and r.epoch = $3 and r.key = jsonb_build_object(%1$s)) limit $4',
                              (select string_agg(format('%L, x.%I', c, c), ', ') from unnest(pk) c), t)
                 using r.source, r.tbl, r.epoch, budget loop
        begin
          perform bus.apply_row(jsonb_build_object('table', r.tbl, 'op', 'delete', 'key', k), r.source);
        exception when others then
          perform bus.reject(jsonb_build_object('reason', 'reconcile_delete', 'table', r.tbl, 'key', k, 'error', sqlerrm));
        end;
        insert into bus.reconcile_keys (source, tbl, epoch, key) values (r.source, r.tbl, r.epoch, k) on conflict do nothing;
        m := m + 1;
      end loop;
    end if;
    n := n + m;
    if m < budget then  -- tidak ada lagi yang tersisa: selesai
      delete from bus.reconcile_keys x where x.source = r.source and x.tbl = r.tbl and x.epoch = r.epoch;
      delete from bus.reconcile_runs x where x.source = r.source and x.tbl = r.tbl and x.epoch = r.epoch;
    end if;
    perform bus.report_rejects(r.source);
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION bus.reject (
  p_detail jsonb
)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  select set_config('bus.rejects', case when jsonb_array_length(r) < 10 then r || jsonb_build_array(p_detail) else r end::text, true),
         set_config('bus.rejects_n', (coalesce(nullif(current_setting('bus.rejects_n', true), ''), '0')::int + 1)::text, true)
    from (select coalesce(nullif(current_setting('bus.rejects', true), ''), '[]')::jsonb r) x;
$function$;

CREATE OR REPLACE FUNCTION bus.report_rejects (
  p_source text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  r jsonb := nullif(current_setting('bus.rejects', true), '')::jsonb;
  d jsonb;
begin
  if r is null then
    return;
  end if;
  d := jsonb_build_object('source', p_source, 'count', current_setting('bus.rejects_n', true)::int, 'events', r);
  perform set_config('bus.rejects', '', true);
  perform set_config('bus.rejects_n', '', true);
  if bus.me() = 'admin' then
    -- ops.raise_alert hanya ada di admin (fungsi ini dibagi ke creator/brand): dipanggil lewat regprocedure seperti handler bus_in
    execute format('select %s($1, $2, $3)', to_regprocedure('ops.raise_alert(text, text, jsonb, interval)')::regproc)
      using 'bus.rejected_payload', 'critical', d;
  else
    perform bus.emit('admin', 'bus.rejected', d);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION bus_in.tracking_view_snapshots_applied (
  p_op  text,
  p_row jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if p_op = 'upsert' then
    perform tracking.apply_snapshot((p_row ->> 'id')::bigint);
  end if;
exception when others then
  perform tracking.alert_apply_failed((p_row ->> 'submission_id')::uuid, null, 'snapshot', sqlerrm);
end $function$;

CREATE OR REPLACE FUNCTION market.run_lifecycle()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  grace interval := (ops.cfg('tracking.final_grace_hours', '72'))::numeric * interval '1 hour';
  active constant tracking.submission_status[] := array['validating', 'in_review', 'tracking', 'flagged', 'appealed']::tracking.submission_status[];
  r record;
  fin bigint;
  e text;
  step text;
  n int;
begin
  -- Suspend berdurasi yang sudah lewat → active lagi (sanksi tetap tercatat dengan until); entry point yang mensyaratkan
  -- status 'active' (submit, sosmed, org, notifikasi) tidak terkunci selamanya menunggu unsuspend manual (R75).
  update market.profiles set status = 'active', suspended_until = null where status = 'suspended' and suspended_until <= now();
  for r in update market.campaigns set status = 'live' where status = 'scheduled' and start_at <= now() returning id, org_id loop
    perform market.notify_org(r.org_id, array['brand_owner', 'brand_manager']::market.org_role[], 'campaign.live',
                              market.campaign_ref(r.id));
    perform market.announce_campaign(r.id);
  end loop;
  update market.campaigns set status = 'tracking' where status in ('live', 'paused') and submit_deadline <= now();
  perform finance.void_stale_addons();

  perform finance.finalize_settlements();

  for r in select s.id, s.posted_at + make_interval(days => c.view_window_days) as window_end, s.next_poll_at
             from tracking.submissions s join market.campaigns c on c.id = s.campaign_id
            where s.status = 'tracking'
              and (s.posted_at + make_interval(days => c.view_window_days) <= now() or c.status in ('exhausted', 'settling', 'settled'))
            order by s.id
            for update of s skip locked loop
    select v.id into fin from tracking.view_snapshots v where v.submission_id = r.id and v.is_final;
    e := null;
    -- Snapshot final yang belum diproses apply_snapshot (hook replika gagal → alert, CX11): proses ulang lewat apply_snapshot
    -- (cek fraud + accrual + lock), bukan accrual langsung; masih gagal → tetap tracking (dicoba lagi run berikutnya) + alert.
    -- Penanda = applied_snapshot_id milik admin (last_snapshot_at replika creator tiba walau hook gagal, CL15/CX12); naik
    -- berurutan, jadi ≥ final = final sudah diproses (snapshot sesudah final bisa tiba saat replika status tertinggal, CX15).
    if fin is not null and not exists (select 1 from tracking.submissions t where t.id = r.id and t.applied_snapshot_id >= fin) then
      begin
        perform tracking.apply_snapshot(fin);
      exception when others then
        e := sqlerrm;
        step := 'lifecycle';
      end;
    -- Sudah diproses (mis. flagged saat snapshot final tiba, lalu flag diselesaikan) → accrual final + lock; final yang dilewati
    -- admin_ops (final_skipped) → lock tanpa accrual-nya. Accrual gagal → alert (bisa dilewati), submisi lain tetap jalan (O1-4).
    elsif fin is not null then
      begin
        if not (select t.final_skipped from tracking.submissions t where t.id = r.id) then
          perform finance.accrue_earnings(r.id, fin);
        end if;
        update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id and status = 'tracking';
      exception when others then
        e := sqlerrm;
        step := 'lock';
      end;
    -- Grace dihitung dari yang terakhir: akhir window atau masuk tracking (approve/overturn telat) → poll final sempat jalan (R69).
    -- Lock tanpa snapshot final hanya bila antrean creator → admin sudah melewati batas itu (ping creator yang dikirim sesudahnya
    -- sudah tiba, FIFO): bus macet bukan berarti snapshot final tidak ada — earning tidak dikunci dari data yang tertinggal.
    elsif greatest(r.window_end, coalesce((select max(d.created_at) from trust.review_decisions d
                                            where d.target_type = 'submission' and d.target_id = r.id
                                              and d.decision in ('approve', 'auto_approve', 'overturn')), r.window_end)) + grace
          < least(now(), coalesce((select p.pinged_at from ops.bus_peers p where p.source = 'creator'), '-infinity')) then
      update tracking.submissions set status = 'locked', locked_at = now(), next_poll_at = null where id = r.id;
      perform ops.raise_alert('tracking.final_missing', 'warning', jsonb_build_object('submission_id', r.id));
    elsif r.next_poll_at is null or r.next_poll_at > now() + interval '1 hour' then
      update tracking.submissions set next_poll_at = now() where id = r.id;
    end if;
    if e is not null then  -- satu alert terbuka per snapshot pemblokir (bukan dedupe per jenis)
      perform tracking.alert_apply_failed(r.id, case when step = 'lock' then fin end, step, e);
    end if;
  end loop;

  -- Submisi dibuat di project creator dan tiba lewat bus (FIFO). Campaign yang tutup karena deadline baru settle setelah ping
  -- creator yang dikirim > 1 menit sesudah deadline tiba: semua submisi yang diterima creator sebelum deadline sudah di sini (R83-1).
  update market.campaigns c set status = 'settling'
   where c.status in ('tracking', 'exhausted')
     and (c.status <> 'tracking'
          or coalesce((select p.pinged_at from ops.bus_peers p where p.source = 'creator'), '-infinity') > c.submit_deadline + interval '1 minute')
     and not exists (select 1 from tracking.submissions s where s.campaign_id = c.id and s.status = any (active))
     and not exists (select 1 from finance.pool_settlements ps join finance.reward_pools rp on rp.id = ps.pool_id
                     where rp.campaign_id = c.id);
  for r in update market.campaigns c set status = 'settled'
            where c.status = 'settling'
              and not exists (select 1 from tracking.submissions s where s.campaign_id = c.id
                              and (s.status = any (active) or s.status = 'locked'))
            returning c.id, c.org_id loop
    perform market.notify_org(r.org_id, array['brand_owner', 'brand_manager', 'brand_finance']::market.org_role[], 'campaign.settled',
      market.campaign_ref(r.id) || jsonb_build_object('leftover',
        coalesce((select jsonb_agg(finance.amount_ref(rp.reward_type_id, finance.balance(finance.account('campaign_pool', rp.id, rp.reward_type_id)))
                                   || jsonb_build_object('pool_id', rp.id) order by rp.id)
                  from finance.reward_pools rp where rp.campaign_id = r.id), '[]')));
    perform finance.return_noncash_leftover(r.id);
  end loop;

  -- Kesehatan job tracking (F-A01): submisi macet (tracking.lagging_count, termasuk worker mati) → alert (maks satu per 6 jam).
  n := tracking.lagging_count();
  if n > 0 then
    perform ops.raise_alert('tracking.lag', 'warning', jsonb_build_object('overdue', n), interval '6 hours');
  end if;

  perform finance.retry_instant_payouts();
  perform trust.auto_approve_overdue();
end $function$;

CREATE OR REPLACE FUNCTION tracking.alert_apply_failed (
  p_submission uuid,
  p_snapshot   bigint,
  p_step       text,
  p_error      text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  sid bigint := coalesce(p_snapshot, (select min(x.id) from tracking.view_snapshots x where x.submission_id = p_submission
                                        and x.id > coalesce((select t.applied_snapshot_id from tracking.submissions t
                                                             where t.id = p_submission), 0)));
begin
  if not exists (select 1 from ops.alerts a where a.kind = 'tracking.apply_failed' and a.resolved_at is null
                    and a.payload ->> 'snapshot_id' = sid::text) then
    perform ops.raise_alert('tracking.apply_failed', 'critical', jsonb_build_object('snapshot_id', sid, 'submission_id', p_submission,
                                                                                 'step', p_step, 'error', p_error));
  end if;
end $function$;

REVOKE ALL ON FUNCTION "bus"."reconcile_apply"(integer) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus"."reconcile_apply"(integer) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus"."reconcile_apply"(integer) TO "postgres";

REVOKE ALL ON FUNCTION "tracking"."alert_apply_failed"(uuid, bigint, text, text) FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."alert_apply_failed"(uuid, bigint, text, text) FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."alert_apply_failed"(uuid, bigint, text, text) TO "postgres";

SELECT cron.schedule_in_database('bus-reconcile', '30 seconds', 'select bus.reconcile_apply()', 'postgres', NULL, true);
SET local check_function_bodies = off;

DROP FUNCTION "tracking"."alert_apply_failed"(uuid, bigint, text, text);

CREATE OR REPLACE FUNCTION bus_in.tracking_view_snapshots_applied (
  p_op  text,
  p_row jsonb
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
begin
  if p_op = 'upsert' then
    perform tracking.apply_snapshot((p_row ->> 'id')::bigint);
  end if;
exception when others then
  perform tracking.alert_apply_failed((p_row ->> 'submission_id')::uuid, null, 'snapshot', sqlerrm, (p_row ->> 'id')::bigint);
end $function$;

CREATE OR REPLACE FUNCTION tracking.alert_apply_failed (
  p_submission uuid,
  p_snapshot   bigint,
  p_step       text,
  p_error      text,
  p_fallback   bigint DEFAULT NULL::bigint
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  sid bigint := coalesce(p_snapshot, (select min(x.id) from tracking.view_snapshots x where x.submission_id = p_submission
                                        and x.id > coalesce((select t.applied_snapshot_id from tracking.submissions t
                                                             where t.id = p_submission), 0)), p_fallback);
begin
  if not exists (select 1 from ops.alerts a where a.kind = 'tracking.apply_failed' and a.resolved_at is null
                    and a.payload ->> 'snapshot_id' = sid::text) then
    perform ops.raise_alert('tracking.apply_failed', 'critical', jsonb_build_object('snapshot_id', sid, 'submission_id', p_submission,
                                                                                 'step', p_step, 'error', p_error));
  end if;
end $function$;

REVOKE ALL ON FUNCTION "tracking"."alert_apply_failed"(uuid, bigint, text, text, bigint) FROM PUBLIC;

REVOKE ALL ON FUNCTION "tracking"."alert_apply_failed"(uuid, bigint, text, text, bigint) FROM "postgres";

GRANT EXECUTE ON FUNCTION "tracking"."alert_apply_failed"(uuid, bigint, text, text, bigint) TO "postgres";
