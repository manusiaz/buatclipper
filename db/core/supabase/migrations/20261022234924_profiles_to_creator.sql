SET local check_function_bodies = off;

-- 4DB-4a: isi profil pindah ke project creator. Migration ini tidak memindahkan data lama; DB admin yang sudah berisi profil
-- harus dipindah dulu (kalau tidak: username di creator tidak tahu username lama, profil lama tanpa salinan creator).
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM market.profiles) THEN
    RAISE EXCEPTION 'admin sudah berisi profil: pindahkan isi profil + file avatars ke project creator dulu (4DB-4a)';
  END IF;
END $$;

DROP POLICY "avatars_own_update" ON "storage"."objects";

DROP POLICY "avatars_own_write" ON "storage"."objects";

DROP TRIGGER "profiles_replicate" ON "market"."profiles";

ALTER TABLE "market"."campaign_invites"
  DROP CONSTRAINT "campaign_invites_user_id_fkey";

ALTER TABLE "market"."org_members"
  DROP CONSTRAINT "org_members_user_id_fkey";

DROP FUNCTION "api"."ensure_profile"(text, text, text, text);

DROP FUNCTION "bus_in"."profile_ensure"(jsonb);

DROP FUNCTION "market"."ensure_member_profile"(uuid, text, text);

CREATE OR REPLACE FUNCTION api.bridge_close_account (
  p_user uuid
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
declare
  pr market.profiles;
begin
  select * into pr from market.profiles p where p.id = p_user for update;
  if not found then
    return jsonb_build_object('ok', true, 'reason', 'no_profile');
  end if;
  if pr.status = 'closed' then
    return jsonb_build_object('ok', true, 'reason', 'already_closed');
  end if;
  if exists (select 1 from finance.ledger_accounts a join finance.ledger_entries e on e.account_id = a.id
             where a.owner_type = 'user_wallet' and a.owner_id = p_user and e.state in ('pending', 'available')
             group by a.id, e.state having sum(e.amount) <> 0) then
    return jsonb_build_object('ok', false, 'reason', 'balance_remaining');
  end if;
  if exists (select 1 from finance.payouts p where p.user_id = p_user and p.status in ('requested', 'on_hold', 'processing', 'failed')) then
    return jsonb_build_object('ok', false, 'reason', 'payout_in_progress');
  end if;
  if exists (select 1 from finance.fulfillments f where f.user_id = p_user and f.status in ('requested', 'on_hold', 'processing', 'failed')) then
    return jsonb_build_object('ok', false, 'reason', 'fulfillment_in_progress');
  end if;

  update tracking.submissions set status = 'forfeited', next_poll_at = null where user_id = p_user and status in ('tracking', 'flagged');
  update tracking.submissions set status = 'rejected' where user_id = p_user and status in ('validating', 'in_review');
  update tracking.submissions set status = 'rejected_final' where user_id = p_user and status = 'appealed';
  update market.claims set status = 'released' where user_id = p_user and status = 'open';
  delete from vault.secrets v where v.id in (select a.token_ref from tracking.social_accounts a where a.user_id = p_user);
  delete from tracking.social_accounts a
   where a.user_id = p_user and not exists (select 1 from tracking.submissions s where s.social_account_id = a.id);
  update tracking.social_accounts set status = 'disconnected', token_ref = null, handle = 'deleted', followers = null
   where user_id = p_user;
  update market.profiles set referral_code = null, suspended_until = null, status = 'closed' where id = p_user;
  perform bus.emit('creator', 'profile.anonymize', jsonb_build_object('user_id', p_user));  -- isi profil milik creator
  return jsonb_build_object('ok', true, 'reason', null);
end $function$;

CREATE OR REPLACE FUNCTION bus_in.referral_record (
  p jsonb
)
  RETURNS void
  LANGUAGE sql
  SET search_path TO ''
  AS $function$
  insert into market.referrals (referred_id, referrer_id, code)
  select (p ->> 'user_id')::uuid, r.id, r.referral_code from market.profiles r
   where r.referral_code = p ->> 'code' and r.id <> (p ->> 'user_id')::uuid
  on conflict do nothing;
$function$;

CREATE TRIGGER profiles_replicate
  AFTER INSERT OR DELETE OR UPDATE ON market.profiles
  FOR EACH ROW
  EXECUTE FUNCTION bus.replicate('brand:status,suspended_until,trust_score', 'creator:status,suspended_until,trust_score');

REVOKE ALL ON FUNCTION "bus_in"."referral_record"(jsonb) FROM PUBLIC;

REVOKE ALL ON FUNCTION "bus_in"."referral_record"(jsonb) FROM "postgres";

GRANT EXECUTE ON FUNCTION "bus_in"."referral_record"(jsonb) TO "postgres";
