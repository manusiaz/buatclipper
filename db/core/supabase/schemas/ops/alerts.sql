-- Alert admin (F-X01 penerima admin, F-A01): payout gagal, selisih/ID yatim rekonsiliasi, fulfillment macet, lonjakan fraud flag,
-- job tracking telat. Ditulis fungsi definer lewat ops.raise_alert; dibaca & ditutup admin apa pun (aal2).
create table ops.alerts (
  id bigint generated always as identity primary key,
  kind text not null check (kind ~ '^[a-z_]+(\.[a-z_]+)+$'),
  severity text not null default 'warning' check (severity in ('info', 'warning', 'critical')),
  payload jsonb not null default '{}' check (jsonb_typeof(payload) = 'object'),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid,
  constraint alerts_resolution check ((resolved_at is null) = (resolved_by is null))
);
create index alerts_open_idx on ops.alerts (kind, created_at desc) where resolved_at is null;

alter table ops.alerts enable row level security;
create policy alerts_iss on ops.alerts as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy alerts_admin_read on ops.alerts for select to authenticated using ((select ops.has_admin()));  -- policy:core.admin-aal2
grant select on ops.alerts to authenticated;

create view api.alerts with (security_invoker = true) as
  select id, kind, severity, payload, created_at, resolved_at, resolved_by from ops.alerts;
grant select on api.alerts to authenticated;

-- Nilai config E-25 (jsonb) dengan default. Hanya dipanggil fungsi definer.
create function ops.cfg(p_key text, p_default jsonb default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  return coalesce((select s.value from ops.settings s where s.key = p_key), p_default);
end $$;

-- Tulis alert. p_dedupe: lewati kalau alert jenis sama yang belum ditutup sudah ada dalam rentang itu (job berulang).
create function ops.raise_alert(p_kind text, p_severity text, p_payload jsonb, p_dedupe interval default null) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  aid bigint;
begin
  if p_dedupe is not null and exists (select 1 from ops.alerts a where a.kind = p_kind and a.resolved_at is null
                                        and a.created_at > now() - p_dedupe) then
    return null;
  end if;
  insert into ops.alerts (kind, severity, payload) values (p_kind, p_severity, coalesce(p_payload, '{}')) returning id into aid;
  -- F-X01 admin (alur 4): job tracking gagal, lonjakan fraud, payout gagal, selisih rekonsiliasi → email admin terkait lewat
  -- bridge identity (tanpa PII; payload tidak dikirim). Maks satu email per jenis per jam supaya alert beruntun tidak spam.
  if p_kind in ('tracking.lag', 'tracking.final_missing', 'fraud.flag_spike', 'payout.failed', 'payout.instant_stuck',
                'reconcile.ledger', 'reconcile.orphans')
     and not exists (select 1 from ops.alerts a where a.kind = p_kind and a.id <> aid and a.created_at > now() - interval '1 hour') then
    perform ops.invoke_function('bridge', jsonb_build_object('action', 'notify_admins', 'kind', p_kind, 'severity', p_severity,
                                                             'alert_id', aid));
  end if;
  return aid;
end $$;

create function api.resolve_alert(p_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not ops.has_admin() then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  update ops.alerts set resolved_at = now(), resolved_by = (select auth.uid()) where id = p_id and resolved_at is null;
  if not found then
    raise exception 'not_found:alert' using errcode = 'P0002';
  end if;
  insert into ops.audit_logs (actor_id, action, target, after) values ((select auth.uid()), 'alert.resolve', 'alert:' || p_id, null);
end $$;

revoke execute on function ops.cfg(text, jsonb), ops.raise_alert(text, text, jsonb, interval), api.resolve_alert(bigint) from public;
grant execute on function api.resolve_alert(bigint) to authenticated;
