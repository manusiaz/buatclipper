-- §12 sanksi bertingkat (peringatan → tahan earning → hangus → suspend 30 hari → ban): setiap sanksi atas clipper tercatat
-- di sini dan bisa dibanding SEKALI oleh clipper (api.appeal_sanction), diputus admin_moderator (api.decide_sanction_appeal).
-- Ditulis resolve_fraud_flag (fraud queue) dan manage_user (suspend/ban dari manajemen user).
create table trust.sanctions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references market.profiles (id),
  kind text not null check (kind in ('warn', 'hold', 'reverse', 'suspend', 'ban')),
  flag_id uuid references trust.fraud_flags (id),
  reason text check (length(reason) <= 500),
  created_by uuid,
  created_at timestamptz not null default now(),
  appeal_message text check (length(appeal_message) between 10 and 1000),
  appealed_at timestamptz,
  decision text check (decision in ('upheld', 'overturned')),
  decision_note text check (length(decision_note) between 3 and 500),
  decided_by uuid,
  decided_at timestamptz,
  constraint sanctions_appeal_complete check ((appealed_at is null) = (appeal_message is null)),
  constraint sanctions_decision_complete check ((decision is null) = (decided_at is null)
                                                and (decision is null or (appealed_at is not null and decided_by is not null)))
);
create index sanctions_user_idx on trust.sanctions (user_id, created_at desc);
create index sanctions_flag_idx on trust.sanctions (flag_id);
create index sanctions_appeal_queue_idx on trust.sanctions (appealed_at) where appealed_at is not null and decision is null;

alter table trust.sanctions enable row level security;
create policy sanctions_iss on trust.sanctions as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy sanctions_own_read on trust.sanctions for select to authenticated using (user_id = (select auth.uid()));  -- policy:core.rls-self
create policy sanctions_admin_read on trust.sanctions for select to authenticated  -- policy:core.admin-aal2
  using ((select ops.has_admin('admin_moderator', 'admin_support')));
grant select on trust.sanctions to authenticated;

create function trust.record_sanction(p_user uuid, p_kind text, p_flag uuid, p_reason text) returns uuid
language sql security definer set search_path = '' as $$
  insert into trust.sanctions (user_id, kind, flag_id, reason, created_by)
  values (p_user, p_kind, p_flag, left(nullif(btrim(p_reason), ''), 500), (select auth.uid()))
  returning id;
$$;

-- Clipper membanding sanksinya sendiri, sekali per sanksi; masuk antrean moderasi (tab Banding sanksi).
create function api.appeal_sanction(p_sanction uuid, p_message text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  s trust.sanctions;
begin
  if uid is null or not ops.iss_ok() then
    raise exception 'auth:no_session' using errcode = '42501';
  end if;
  select * into s from trust.sanctions x where x.id = p_sanction and x.user_id = uid for update;
  if not found then
    raise exception 'not_found:sanction' using errcode = 'P0002';
  end if;
  if s.appealed_at is not null then
    raise exception 'already_appealed' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_message, ''))) not between 10 and 1000 then
    raise exception 'invalid:message' using errcode = 'P0001';
  end if;
  update trust.sanctions set appeal_message = btrim(p_message), appealed_at = now() where id = s.id;
end $$;

-- admin_moderator memutus banding. Dibatalkan → efeknya dibalik sejauh aman: suspend → aktif lagi; ban → aktif + login dibuka
-- (bridge ban_user unban); tahan earning → flag di-dismiss & tracking lanjut; penalti Trust Score dikembalikan. Earning yang
-- sudah hangus (reverse/ban) tidak dijurnal ulang otomatis — keputusan finance terpisah.
create function api.decide_sanction_appeal(p_sanction uuid, p_decision text, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  s trust.sanctions;
  restore smallint;
  sub uuid;
begin
  if not ops.has_admin('admin_moderator') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if p_decision is null or p_decision not in ('upheld', 'overturned') then
    raise exception 'invalid:decision' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_note, ''))) < 3 then
    raise exception 'invalid:note' using errcode = 'P0001';
  end if;
  select * into s from trust.sanctions x where x.id = p_sanction for update;
  if not found then
    raise exception 'not_found:sanction' using errcode = 'P0002';
  end if;
  if s.appealed_at is null or s.decision is not null then
    raise exception 'invalid_state:appeal' using errcode = 'P0001';
  end if;
  update trust.sanctions set decision = p_decision, decision_note = left(btrim(p_note), 500), decided_by = uid, decided_at = now()
   where id = s.id;
  if p_decision = 'overturned' then
    if s.kind = 'suspend' then
      update market.profiles set status = 'active', suspended_until = null where id = s.user_id and status = 'suspended';
    elsif s.kind = 'ban' then
      update market.profiles set status = 'active', suspended_until = null where id = s.user_id and status = 'banned';
      perform ops.invoke_function('bridge', jsonb_build_object('action', 'ban_user', 'user_id', s.user_id, 'unban', true));
    elsif s.kind = 'hold' and s.flag_id is not null then
      update trust.fraud_flags set status = 'dismissed', resolved_by = uid, resolved_at = now() where id = s.flag_id and status = 'held';
      sub := (select f.target_id from trust.fraud_flags f where f.id = s.flag_id and f.target_type = 'submission');
      if sub is not null and not exists (select 1 from trust.fraud_flags o where o.target_type = 'submission' and o.target_id = sub
                                           and o.status in ('open', 'held')) then
        update tracking.submissions set status = 'tracking', next_poll_at = coalesce(next_poll_at, now())
         where id = sub and status = 'flagged';
      end if;
    end if;
    restore := case s.kind when 'warn' then 5 when 'reverse' then 10 when 'suspend' then 20 when 'ban' then 50 end;
    if restore is not null and s.flag_id is not null then  -- penalti Trust Score hanya dari fraud queue
      insert into trust.score_events (user_id, delta, reason, ref_id, created_by)
      values (s.user_id, restore, 'appeal_overturned', s.id::text, uid);
    end if;
  end if;
  perform ops.enqueue_notification(s.user_id, 'sanction.appeal_decided',
                                   jsonb_build_object('sanction_id', s.id, 'kind', s.kind, 'decision', p_decision));
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'sanction.appeal_decide', 'sanction:' || s.id, jsonb_build_object('kind', s.kind, 'user_id', s.user_id),
          jsonb_build_object('decision', p_decision, 'note', left(btrim(p_note), 500)));
end $$;

revoke execute on function trust.record_sanction(uuid, text, uuid, text), api.appeal_sanction(uuid, text),
  api.decide_sanction_appeal(uuid, text, text) from public;
grant execute on function api.appeal_sanction(uuid, text), api.decide_sanction_appeal(uuid, text, text) to authenticated;
