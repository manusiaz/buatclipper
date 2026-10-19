-- job:broadcast-dispatch (tiap menit, F-A12): broadcast yang sudah waktunya → penerima sesuai segmen → enqueue_notification
-- (event broadcast.sent = promosi: email ikut preferensi E-34). Segmen (semua opsional, AND):
--   platforms [..]        punya akun sosmed verified di salah satu platform
--   min_trust_score/max_trust_score
--   kyc approved|not_approved   keputusan KYC terakhir yang dicatat core (record_review target kyc)
--   active_days N         ada claim atau submisi dalam N hari terakhir
-- Penerima = profil berstatus active. Email/push hanya kalau kanal broadcast memuatnya; channels ikut payload untuk worker notify.
create function ops.dispatch_broadcasts() returns int
language plpgsql security definer set search_path = '' as $$
declare
  b ops.broadcasts;
  seg jsonb;
  r record;
  n int;
  total int := 0;
begin
  for b in select * from ops.broadcasts where sent_at is null and scheduled_at <= now()
            order by scheduled_at for update skip locked loop
    seg := b.segment;
    n := 0;
    for r in
      select p.id from market.profiles p
       where p.status = 'active'
         and (not seg ? 'platforms'
              or exists (select 1 from tracking.social_accounts a where a.user_id = p.id and a.status = 'verified'
                         and a.platform::text in (select jsonb_array_elements_text(seg -> 'platforms'))))
         and (not seg ? 'min_trust_score' or p.trust_score >= (seg ->> 'min_trust_score')::int)
         and (not seg ? 'max_trust_score' or p.trust_score <= (seg ->> 'max_trust_score')::int)
         and (not seg ? 'kyc'
              or (seg ->> 'kyc' = 'approved') = coalesce((select d.decision = 'approve' from trust.review_decisions d
                                                          where d.target_type = 'kyc' and d.target_id = p.id
                                                          order by d.created_at desc, d.id desc limit 1), false))
         and (not seg ? 'active_days'
              or exists (select 1 from market.claims cl where cl.user_id = p.id
                         and cl.created_at >= now() - make_interval(days => (seg ->> 'active_days')::int))
              or exists (select 1 from tracking.submissions s where s.user_id = p.id
                         and s.created_at >= now() - make_interval(days => (seg ->> 'active_days')::int)))
    loop
      perform ops.enqueue_notification(r.id, 'broadcast.sent',
                                       jsonb_build_object('broadcast_id', b.id, 'title', b.title, 'body', b.body,
                                                          'channels', to_jsonb(b.channels)),
                                       'email' = any (b.channels) or 'push' = any (b.channels));
      n := n + 1;
    end loop;
    update ops.broadcasts set sent_at = now(), recipient_count = n where id = b.id;
    total := total + n;
  end loop;
  return total;
end $$;
revoke execute on function ops.dispatch_broadcasts() from public;
