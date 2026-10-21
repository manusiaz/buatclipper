-- Handoff sesi app native → web: app membuka accounts./app.{domain} di in-app browser yang belum punya cookie SSO.
-- Edge Function session-handoff menyimpan sha256(kode) sekali pakai 60 detik; accounts/handoff menukarnya jadi sesi web.
-- Kode mentah tidak pernah disimpan. Hanya service role lewat svc_* (tanpa policy browser).
create table member.session_handoffs (
  code_hash bytea primary key check (octet_length(code_hash) = 32),
  user_id uuid not null references auth.users (id) on delete cascade,
  next text not null check (char_length(next) between 1 and 2000),
  expires_at timestamptz not null,
  used_at timestamptz
);
create index session_handoffs_user_idx on member.session_handoffs (user_id, expires_at);
create index session_handoffs_expires_idx on member.session_handoffs (expires_at);

alter table member.session_handoffs enable row level security;
