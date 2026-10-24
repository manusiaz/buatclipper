-- E-15 jurnal double-entry, satu-satunya jalan uang bergerak. Ditegakkan di database, bukan hanya di fungsi:
--   * append-only (koreksi = jurnal baru);
--   * tiap transaksi seimbang per reward type (constraint trigger, dicek saat commit);
--   * state hanya untuk akun user_wallet = bucket S-04: pending → available → withdrawn. "reversed" (S-04) = transaksi
--     ref_type reversal yang mengembalikan pending ke pool, bukan bucket;
--   * idempoten: posting yang sama (ref_type, ref_id, akun, bucket) tidak bisa tercatat dua kali. Accrual memakai
--     ref_id = <snapshot_id>:<rule_id>.
create type finance.earning_state as enum ('pending', 'available', 'withdrawn');

create table finance.ledger_entries (
  id bigint generated always as identity primary key,
  txn_id uuid not null,
  account_id uuid not null,
  reward_type_id uuid not null,
  amount numeric(30, 10) not null check (amount <> 0),
  state finance.earning_state,
  ref_type text not null check (ref_type in ('accrual', 'release', 'reversal', 'payout', 'payout_return', 'invoice_payment',
                                             'fee', 'refund', 'rollover', 'fulfillment', 'referral_bonus', 'adjustment')),
  ref_id text not null,
  created_at timestamptz not null default now(),
  constraint ledger_entries_account_fk foreign key (account_id, reward_type_id)
    references finance.ledger_accounts (id, reward_type_id),
  constraint ledger_entries_idempotent unique nulls not distinct (ref_type, ref_id, account_id, state)
);
create index ledger_entries_txn_idx on finance.ledger_entries (txn_id);
create index ledger_entries_account_idx on finance.ledger_entries (account_id, state);
create index ledger_entries_ref_idx on finance.ledger_entries (ref_id text_pattern_ops);  -- tab Ledger admin: ref persis & awalan

create trigger ledger_entries_append_only before update or delete on finance.ledger_entries
  for each row execute function ops.reject_mutation();

create function finance.check_entry_bucket() returns trigger
language plpgsql set search_path = '' as $$
begin
  if ((select a.owner_type from finance.ledger_accounts a where a.id = new.account_id) = 'user_wallet')
     is distinct from (new.state is not null) then
    raise exception 'state wajib untuk akun user_wallet dan hanya untuk akun itu' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger ledger_entries_bucket before insert on finance.ledger_entries
  for each row execute function finance.check_entry_bucket();

-- Deferred: jalan saat COMMIT di luar konteks RPC security definer (role = authenticated), jadi wajib security definer.
create function finance.check_txn_balanced() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from finance.ledger_entries e where e.txn_id = new.txn_id
             group by e.reward_type_id having sum(e.amount) <> 0) then
    raise exception 'transaksi % tidak seimbang (jumlah per reward type harus 0)', new.txn_id using errcode = '23514';
  end if;
  return null;
end $$;
create constraint trigger ledger_entries_balanced after insert on finance.ledger_entries
  deferrable initially deferred for each row execute function finance.check_txn_balanced();

alter table finance.ledger_entries enable row level security;
create policy ledger_entries_iss on finance.ledger_entries as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy ledger_entries_visible on finance.ledger_entries for select to authenticated  -- policy:core.inherit-parent
  using (exists (select 1 from finance.ledger_accounts a where a.id = account_id));
grant select on finance.ledger_entries to authenticated;
