-- Ticket Expo push yang receipt-nya belum dicek (job:push-receipts). Expo baru tahu token mati (DeviceNotRegistered)
-- setelah pengiriman ke FCM/APNs, jadi receipt dibaca ≥ 15 menit setelah kirim; receipt hanya tersedia ±24 jam.
-- Hanya service role lewat svc_* (tanpa policy browser).
create table member.push_tickets (
  ticket text primary key check (char_length(ticket) between 1 and 200),
  endpoint text not null references member.push_subscriptions (endpoint) on delete cascade,
  created_at timestamptz not null default now()
);
create index push_tickets_created_idx on member.push_tickets (created_at);
create index push_tickets_endpoint_idx on member.push_tickets (endpoint);

alter table member.push_tickets enable row level security;
