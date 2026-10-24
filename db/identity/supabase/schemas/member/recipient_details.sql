-- E-29 data penerima reward non-tunai yang berisi alamat/HP (terenkripsi). reward_type_id = rujukan E-07 di core, tanpa FK.
create table member.recipient_details (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  reward_type_id uuid not null,
  data_enc bytea not null,
  enc_key_version smallint not null check (enc_key_version > 0),
  updated_at timestamptz not null default now(),
  constraint recipient_one_per_reward_type unique (user_id, reward_type_id)
);

alter table member.recipient_details enable row level security;
create policy recipient_own_read on member.recipient_details for select to authenticated using (user_id = (select auth.uid()));  -- policy:identity.rls-self
grant select (id, user_id, reward_type_id, updated_at) on member.recipient_details to authenticated;
