-- F-A07 admin (admin_ops/admin_moderator aal2) atas clipper: trust_override {delta, note} (E-40 admin_override; skor dihitung
-- ulang langsung, rumus = job trust-score) | suspend {days 1–365, reason} | unsuspend {note} | ban {reason} | unban {note}: profil yang di-ban
-- fraud queue kembali active (earning yang sudah di-reverse tetap). Ban/unban login lewat Edge Function identity admin-auth
-- (+ bridge); halaman admin memanggil unban di keduanya. Semua tercatat audit log.
create function api.manage_user(p_user uuid, p_action text, p_params jsonb default '{}') returns void
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := market.session_uid();
  prm jsonb := coalesce(p_params, '{}');
  pr market.profiles;
  delta int;
  days int;
  until_at timestamptz;
begin
  if not ops.has_admin('admin_ops', 'admin_moderator') then
    perform market.fail('auth:forbidden', 'butuh admin_ops/admin_moderator aal2', '42501');
  end if;
  select * into pr from market.profiles where id = p_user for update;
  if pr.id is null then
    perform market.fail('not_found:profile', null, 'P0002');
  end if;
  if nullif(btrim(coalesce(prm ->> 'reason', prm ->> 'note')), '') is null then
    perform market.fail('invalid:reason', 'aksi admin atas user wajib alasan');
  end if;
  if p_action = 'trust_override' then
    delta := market.jnum(prm -> 'delta')::int;
    if delta is null or delta = 0 or delta not between -100 and 100 then
      perform market.fail('invalid:delta', 'delta -100..100, bukan 0');
    end if;
    insert into trust.score_events (user_id, delta, reason, ref_id, created_by) values (pr.id, delta, 'admin_override', left(prm ->> 'note', 200), uid);
    update market.profiles set trust_score = least(100, greatest(0, 50 + (select coalesce(sum(e.delta), 0) from trust.score_events e
                                                                           where e.user_id = pr.id)))
     where id = pr.id;
  elsif p_action = 'suspend' then
    -- {until}: sampai waktu persis (ban login berdurasi dari admin-auth); {days}: 1–365 hari.
    if prm ? 'until' then
      until_at := (prm ->> 'until')::timestamptz;
      if until_at is null or until_at <= now() then
        perform market.fail('invalid:until', 'until harus di masa depan');
      end if;
    else
      days := market.jnum(prm -> 'days')::int;
      if days is null or days not between 1 and 365 then
        perform market.fail('invalid:days', 'suspend 1–365 hari');
      end if;
      until_at := now() + make_interval(days => days);
    end if;
    if pr.status not in ('active', 'suspended') then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'suspended', suspended_until = until_at where id = pr.id;
    update market.claims set status = 'released' where user_id = pr.id and status = 'open';
    perform finance.hold_payouts(pr.id, null, 'profile_suspended');
    perform ops.enqueue_notification(pr.id, 'account.suspended',
                                     jsonb_build_object('until', until_at, 'reason', prm ->> 'reason'));
    perform trust.record_sanction(pr.id, 'suspend', null, prm ->> 'reason');
  elsif p_action = 'unsuspend' then
    if pr.status <> 'suspended' then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'active', suspended_until = null where id = pr.id;
  elsif p_action = 'ban' then
    if pr.status = 'closed' then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'banned' where id = pr.id;
    -- Paritas dengan ban fraud queue (AA-7): pending hangus, tracking berhenti, payout ditahan, clipper dikabari.
    perform trust.apply_ban(pr.id, 'admin', jsonb_build_object('reason', prm ->> 'reason'));
    perform trust.record_sanction(pr.id, 'ban', null, prm ->> 'reason');
  elsif p_action = 'unban' then
    if pr.status = 'closed' then
      perform market.fail('invalid_state:' || pr.status);
    end if;
    update market.profiles set status = 'active', suspended_until = null where id = pr.id and status in ('banned', 'suspended');
  else
    perform market.fail('invalid:action', p_action);
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values (uid, 'user.' || p_action, 'profile:' || pr.id,
          jsonb_build_object('status', pr.status, 'trust_score', pr.trust_score, 'suspended_until', pr.suspended_until),
          prm || jsonb_build_object('status', (select p.status from market.profiles p where p.id = pr.id),
                                    'trust_score', (select p.trust_score from market.profiles p where p.id = pr.id)));
end $$;
revoke execute on function api.manage_user(uuid, text, jsonb) from public;
grant execute on function api.manage_user(uuid, text, jsonb) to authenticated;
