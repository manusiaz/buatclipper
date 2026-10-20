-- job:referral-bonus (F-C16): pengundang menerima finance.referral_bonus_pct % dari earning Rupiah teman yang menjadi Tersedia
-- (entri release bucket available di wallet teman) antara qualified_at dan bonus_until. Dibayar platform: platform_revenue →
-- wallet pengundang (langsung Tersedia; dasar bonusnya sudah lewat lock + hold), bukan potongan earning teman.
-- Idempoten: ref_id = id entri release teman; dibulatkan ke bawah ke rupiah penuh.
create function finance.accrue_referral_bonus() returns void
language plpgsql security definer set search_path = '' as $$
declare
  pct numeric := (ops.cfg('finance.referral_bonus_pct', '5'))::numeric;
  idr uuid := finance.idr();
  rev uuid;
  x record;
  bonus numeric;
begin
  if pct <= 0 then
    return;
  end if;
  rev := finance.account('platform_revenue', null, idr);
  for x in select le.id as entry_id, le.amount, r.referrer_id
             from market.referrals r
             join market.profiles rf on rf.id = r.referrer_id and rf.status = 'active'
             join finance.ledger_accounts a on a.owner_type = 'user_wallet' and a.owner_id = r.referred_id and a.reward_type_id = idr
             join finance.ledger_entries le on le.account_id = a.id and le.state = 'available' and le.ref_type = 'release'
            where r.qualified_at is not null and r.bonus_until is not null and le.amount > 0
              -- C5.3: teman satu NIK/rekening/perangkat dengan pengundang → bonus batal (flag FR-04/FR-05 belum di-dismiss)
              and not exists (select 1 from trust.fraud_flags f
                               where f.target_type = 'profile' and f.signal in ('FR-04', 'FR-05') and f.status <> 'dismissed'
                                 and ((f.target_id = r.referred_id and f.details -> 'related_user_ids' ? r.referrer_id::text)
                                   or (f.target_id = r.referrer_id and f.details -> 'related_user_ids' ? r.referred_id::text)))
              and le.created_at >= r.qualified_at and le.created_at < r.bonus_until
              and not exists (select 1 from finance.ledger_entries b where b.ref_type = 'referral_bonus' and b.ref_id = le.id::text)
            order by le.id loop
    bonus := trunc(x.amount * pct / 100);
    continue when bonus <= 0;
    perform finance.post(gen_random_uuid(), jsonb_build_array(
      finance.e(rev, -bonus, 'referral_bonus', x.entry_id::text),
      finance.e(finance.account('user_wallet', x.referrer_id, idr), bonus, 'referral_bonus', x.entry_id::text, 'available')));
  end loop;
end $$;

revoke execute on function finance.accrue_referral_bonus() from public;
