-- Helper jurnal internal (bukan API, tidak di-grant ke role mana pun). Aturan semua fungsi uang:
--   * satu mutasi = satu finance.post: semua entri satu INSERT, jadi trigger seimbang (ledger_entries_balanced) lolos
--     walau constraint sedang immediate, dan saldo dicek di sini dulu supaya pesan errornya jelas;
--   * idempoten lewat unique (ref_type, ref_id, akun, bucket) — pemanggil yang harus no-op saat replay mengecek dulu;
--   * konvensi tanda: saldo akun = sum(amount). bank_clearing = cermin dunia luar (negatif = dana/stok yang masuk dari luar).

-- Akun ledger get-or-create (owner_id NULL = akun platform).
create function finance.account(p_owner_type text, p_owner_id uuid, p_reward_type uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  aid uuid;
begin
  select a.id into aid from finance.ledger_accounts a
   where a.owner_type = p_owner_type and a.owner_id is not distinct from p_owner_id and a.reward_type_id = p_reward_type;
  if aid is null then
    insert into finance.ledger_accounts (owner_type, owner_id, reward_type_id) values (p_owner_type, p_owner_id, p_reward_type)
    on conflict on constraint ledger_accounts_one_per_owner do nothing
    returning id into aid;
    if aid is null then
      select a.id into aid from finance.ledger_accounts a
       where a.owner_type = p_owner_type and a.owner_id is not distinct from p_owner_id and a.reward_type_id = p_reward_type;
    end if;
  end if;
  return aid;
end $$;

-- Satu entri untuk argumen finance.post. state hanya untuk akun user_wallet (pending/available/withdrawn).
create function finance.e(p_account uuid, p_amount numeric, p_ref_type text, p_ref_id text, p_state text default null)
returns jsonb
language plpgsql immutable set search_path = '' as $$
begin
  return jsonb_build_object('account', p_account, 'amount', p_amount, 'ref_type', p_ref_type, 'ref_id', p_ref_id, 'state', p_state);
end $$;

-- Posting satu transaksi. Entri bernilai 0 dibuang; jumlah per reward type wajib 0.
create function finance.post(p_txn uuid, p_entries jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from jsonb_to_recordset(p_entries) x(account uuid)
             where not exists (select 1 from finance.ledger_accounts a where a.id = x.account)) then
    raise exception 'akun ledger tidak ada dalam transaksi %', p_txn using errcode = '23503';
  end if;
  if exists (select 1 from jsonb_to_recordset(p_entries) x(account uuid, amount numeric)
             join finance.ledger_accounts a on a.id = x.account
             group by a.reward_type_id having sum(x.amount) <> 0) then
    raise exception 'transaksi % tidak seimbang', p_txn using errcode = '23514';
  end if;
  insert into finance.ledger_entries (txn_id, account_id, reward_type_id, amount, state, ref_type, ref_id)
  select p_txn, x.account, a.reward_type_id, x.amount, x.state::finance.earning_state, x.ref_type, x.ref_id
    from jsonb_to_recordset(p_entries) x(account uuid, amount numeric, state text, ref_type text, ref_id text)
    join finance.ledger_accounts a on a.id = x.account
   where x.amount <> 0;
end $$;

-- Saldo satu akun; untuk user_wallet per bucket (p_state), akun lain p_state NULL.
create function finance.balance(p_account uuid, p_state finance.earning_state default null) returns numeric
language plpgsql stable security definer set search_path = '' as $$
begin
  return coalesce((select sum(e.amount) from finance.ledger_entries e
                   where e.account_id = p_account and e.state is not distinct from p_state), 0);
end $$;

-- Reward type Rupiah global (seed: code IDR, owner NULL).
create function finance.idr() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare
  rid uuid := (select rt.id from market.reward_types rt where rt.code = 'IDR' and rt.owner_org_id is null);
begin
  if rid is null then
    raise exception 'reward type IDR global belum ada (seed)' using errcode = 'P0002';
  end if;
  return rid;
end $$;

-- Nominal untuk payload notifikasi (template email identity): {amount, reward_type (kode), unit_label}.
create function finance.amount_ref(p_reward_type uuid, p_amount numeric) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  return (select jsonb_build_object('amount', trim_scale(p_amount), 'reward_type', rt.code, 'unit_label', rt.unit_label)
            from market.reward_types rt where rt.id = p_reward_type);
end $$;

revoke execute on function finance.account(text, uuid, uuid), finance.e(uuid, numeric, text, text, text),
  finance.post(uuid, jsonb), finance.balance(uuid, finance.earning_state), finance.idr(), finance.amount_ref(uuid, numeric) from public;
