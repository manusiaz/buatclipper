-- DIBANGKITKAN spec/gen_states.py dari spec/kg.yaml (states). Jangan edit manual: ubah YAML lalu jalankan ulang.

-- S-01 campaign
create type market.campaign_status as enum ('draft', 'in_review', 'cancelled', 'scheduled', 'rejected', 'live', 'paused', 'tracking', 'exhausted', 'settling', 'settled');

-- S-02 claim
create type market.claim_status as enum ('open', 'submitted', 'expired', 'released');

-- S-03 submission
create type tracking.submission_status as enum ('validating', 'in_review', 'tracking', 'rejected', 'flagged', 'forfeited', 'locked', 'appealed', 'settled', 'rejected_final');

-- S-05 payout
create type finance.payout_status as enum ('requested', 'on_hold', 'processing', 'cancelled', 'paid', 'failed', 'returned');

-- S-06 fulfillment
create type finance.fulfillment_status as enum ('requested', 'on_hold', 'processing', 'cancelled', 'delivered', 'failed', 'returned');

-- Satu fungsi untuk semua state machine: insert wajib mulai dari status awal, update hanya lewat transisi yang diizinkan.
create function ops.check_transition() returns trigger
language plpgsql set search_path = '' as $$
declare
  machine text := tg_argv[0];
  initial text := tg_argv[1];
  allowed jsonb := tg_argv[2]::jsonb;
begin
  if tg_op = 'INSERT' then
    if new.status::text <> initial then
      raise exception '% (%): status awal harus %', tg_table_name, machine, initial using errcode = '23514';
    end if;
  elsif new.status is distinct from old.status then
    if not coalesce((allowed -> (old.status::text)) ? (new.status::text), false) then
      raise exception '% (%): transisi % → % tidak diizinkan', tg_table_name, machine, old.status, new.status
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
