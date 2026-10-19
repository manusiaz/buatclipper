-- Extension yang dipakai schema ini (stack Supabase asli). Di uji lokal tanpa Docker, test-local/stub_supabase.sql
-- menyediakan tiruannya dan file ini dilewati load.py.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault with schema vault;
