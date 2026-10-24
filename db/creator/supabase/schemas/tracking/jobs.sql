-- job:track-due — tiap 15 menit memasukkan submisi jatuh tempo (jadwal admin next_poll_at) ke Queue "tracking". lease_until
-- menahan submisi yang sudah di antrean (1 jam) sampai worker mencatat snapshot dan jadwal admin berikutnya tiba. Akun sosmed
-- yang tidak verified (token kedaluwarsa/dicabut/diputus) tidak dipoll: tracking-nya berhenti sampai pemilik menyambung ulang.
create function tracking.enqueue_due_submissions(p_limit int default 500) returns int
language plpgsql security definer set search_path = '' as $$
declare
  n int := 0;
  s record;
begin
  for s in update tracking.submissions t set lease_until = now() + interval '1 hour'
            where t.id in (select d.id from tracking.submissions d
                             join tracking.social_accounts a on a.id = d.social_account_id and a.status = 'verified'
                           where d.status in ('tracking', 'flagged') and d.next_poll_at <= now()
                             and (d.lease_until is null or d.lease_until <= now())
                             and (d.retry_after is null or d.retry_after <= now())
                           order by d.next_poll_at limit p_limit for update of d skip locked)
            returning t.id, t.platform loop
    perform pgmq.send('tracking', jsonb_build_object('submission_id', s.id, 'platform', s.platform));
    n := n + 1;
  end loop;
  return n;
end $$;

-- Submisi yang tracking-nya berhenti saat akun sosmed kehilangan token (social.token_expired: "tracking 3 video berhenti").
create function tracking.paused_count(p_account uuid) returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from tracking.submissions s where s.social_account_id = p_account and s.status in ('tracking', 'flagged');
$$;
revoke execute on function tracking.enqueue_due_submissions(int), tracking.paused_count(uuid) from public;

-- Queue + jadwal (UTC). track-worker mengambil batch kecil (batas CPU Edge Function 2 detik/request); token-refresh tiap 6 jam
-- (token TikTok 24 jam).
select pgmq.create('tracking');
select cron.schedule('track-due', '*/15 * * * *', $$select tracking.enqueue_due_submissions()$$);
select cron.schedule('track-worker', '*/5 * * * *', $$select ops.invoke_function('track-worker')$$);
select cron.schedule('token-refresh', '0 */6 * * *', $$select ops.invoke_function('refresh-tokens')$$);
