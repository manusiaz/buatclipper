-- Stub objek platform Supabase untuk menguji schema di Postgres 16 polos (BUKAN bagian deliverable).
-- Meniru: role API, auth.jwt()/uid(), auth.users/sessions, storage.buckets/objects + foldername, vault, pg_cron, pg_net, pgmq.
do $$ begin
  create role anon nologin noinherit;
exception when duplicate_object then null; end $$;
do $$ begin
  create role authenticated nologin noinherit;
exception when duplicate_object then null; end $$;
do $$ begin
  create role service_role nologin noinherit bypassrls;
exception when duplicate_object then null; end $$;
do $$ begin
  create role supabase_auth_admin nologin noinherit;
exception when duplicate_object then null; end $$;

create schema extensions;
grant usage on schema extensions to anon, authenticated, service_role, supabase_auth_admin;
create extension pgcrypto with schema extensions;
create extension pgtap with schema extensions;

create schema auth;
grant usage on schema auth to anon, authenticated, service_role, supabase_auth_admin;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  banned_until timestamptz,
  created_at timestamptz not null default now()
);
create table auth.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  ip inet, user_agent text, aal text, created_at timestamptz not null default now()
);
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;
grant execute on function auth.jwt(), auth.uid() to anon, authenticated, service_role, supabase_auth_admin;

create schema storage;
grant usage on schema storage to anon, authenticated, service_role;
create table storage.buckets (
  id text primary key, name text not null, public boolean not null default false,
  file_size_limit bigint, allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text not null, owner uuid, created_at timestamptz not null default now(),
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
grant select, insert, update, delete on storage.objects to anon, authenticated, service_role;
grant select on storage.buckets to anon, authenticated, service_role;
create function storage.foldername(name text) returns text[] language plpgsql immutable as $$
declare _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1:array_length(_parts, 1) - 1];
end $$;
grant execute on function storage.foldername(text) to anon, authenticated, service_role;

create schema vault;
create table vault.secrets (id uuid primary key default gen_random_uuid(), name text unique, secret text not null,
                            description text, updated_at timestamptz default now());
create view vault.decrypted_secrets as select id, name, secret, secret as decrypted_secret, description from vault.secrets;
create function vault.create_secret(new_secret text, new_name text default null, new_description text default '')
returns uuid language sql as $$
  insert into vault.secrets (secret, name, description) values (new_secret, new_name, new_description) returning id
$$;
create function vault.update_secret(secret_id uuid, new_secret text default null, new_name text default null,
                                    new_description text default null)
returns void language sql as $$
  update vault.secrets set secret = coalesce(new_secret, secret), name = coalesce(new_name, name),
         description = coalesce(new_description, description), updated_at = now() where id = secret_id
$$;

create schema cron;
create table cron.job (jobid bigint generated always as identity primary key, jobname text unique, schedule text, command text);
create function cron.schedule(job_name text, schedule text, command text) returns bigint language sql as $$
  insert into cron.job (jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command returning jobid
$$;

create schema net;
create table net.http_request_queue (id bigint generated always as identity primary key, url text, headers jsonb, body jsonb);
create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}',
                              headers jsonb default '{"Content-Type": "application/json"}', timeout_milliseconds int default 5000)
returns bigint language sql as $$
  insert into net.http_request_queue (url, headers, body) values (url, headers, body) returning id
$$;

create schema pgmq;
create table pgmq.messages (msg_id bigint generated always as identity primary key, queue_name text not null, message jsonb,
                            enqueued_at timestamptz default now());
create table pgmq.queues (queue_name text primary key);
create function pgmq.create(queue_name text) returns void language sql as $$
  insert into pgmq.queues values (queue_name) on conflict do nothing
$$;
create function pgmq.send(queue_name text, msg jsonb, delay integer default 0) returns bigint language plpgsql as $$
declare id bigint;
begin
  if not exists (select 1 from pgmq.queues q where q.queue_name = send.queue_name) then
    raise exception 'queue % tidak ada', queue_name;
  end if;
  insert into pgmq.messages (queue_name, message) values (send.queue_name, msg) returning msg_id into id;
  return id;
end $$;

