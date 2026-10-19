-- Leaderboard (F-C13): mingguan global + per campaign, dari views terhitung submisi aktif. Materialized view (data turunan,
-- bukan entitas), di-refresh tiap jam oleh job leaderboard-refresh (REFRESH CONCURRENTLY butuh unique index tanpa NULL,
-- jadi dua view terpisah). MV tidak punya RLS: browser membacanya lewat api.leaderboard, yang menyaring baris campaign
-- lewat RLS campaigns supaya campaign privat tidak bocor.
create materialized view market.leaderboard_weekly as
  select date_trunc('week', s.created_at) as week_start, s.user_id, sum(s.counted_views)::bigint as views,
         rank() over (partition by date_trunc('week', s.created_at) order by sum(s.counted_views) desc)::int as rank
  from tracking.submissions s
  where s.status in ('tracking', 'locked', 'settled')
  group by date_trunc('week', s.created_at), s.user_id;
create unique index leaderboard_weekly_key on market.leaderboard_weekly (week_start, user_id);

create materialized view market.leaderboard_campaign as
  select s.campaign_id, s.user_id, sum(s.counted_views)::bigint as views,
         rank() over (partition by s.campaign_id order by sum(s.counted_views) desc)::int as rank
  from tracking.submissions s
  where s.status in ('tracking', 'locked', 'settled')
  group by s.campaign_id, s.user_id;
create unique index leaderboard_campaign_key on market.leaderboard_campaign (campaign_id, user_id);

grant select on market.leaderboard_weekly, market.leaderboard_campaign to authenticated;

create function market.refresh_leaderboard() returns void
language plpgsql security definer set search_path = '' as $$
begin
  refresh materialized view concurrently market.leaderboard_weekly;
  refresh materialized view concurrently market.leaderboard_campaign;
end $$;
revoke execute on function market.refresh_leaderboard() from public;
