-- fn:enqueue_notification (brand): inbox & pengiriman email/push dikelola admin; di sini hanya event notify.user ke admin
-- (bus_in.notify_user di admin memanggil ops.enqueue_notification aslinya). Tanda tangan sama dengan versi admin.
create function ops.enqueue_notification(p_user uuid, p_event text, p_payload jsonb default '{}', p_email boolean default true)
returns bigint
language plpgsql security definer set search_path = '' as $$
begin
  perform bus.emit('admin', 'notify.user', jsonb_build_object('user_id', p_user, 'event', p_event, 'payload', coalesce(p_payload, '{}'),
                                                               'email', p_email));
  return null;
end $$;
revoke execute on function ops.enqueue_notification(uuid, text, jsonb, boolean) from public;
