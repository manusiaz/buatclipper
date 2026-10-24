-- View yang boleh dibaca browser. security_invoker: hak & RLS tabel dasar tetap berlaku untuk pemanggil.
create view api.my_kyc with (security_invoker = true) as
  select user_id, nik_last4, legal_name, status, reject_reason, submitted_at, decided_at
  from member.kyc_records;

create view api.my_consents with (security_invoker = true) as
  select kind, version, granted_at, revoked_at
  from member.consents;

create view api.legal_versions with (security_invoker = true) as
  select kind, version, published_at, url
  from member.legal_versions;

-- Data penerima reward milik sendiri (isi terenkripsi tidak ikut): app clipper memakai id-nya sebagai recipient_ref klaim.
create view api.my_recipients with (security_invoker = true) as
  select id, reward_type_id, updated_at from member.recipient_details;
-- F-A11: audit log identity (KYC, role, ekspor PII) untuk admin_super; baris dibatasi RLS audit_logs_super_read.
create view api.audit_logs with (security_invoker = true) as
  select id, actor_id, action, target, before, after, at from member.audit_logs;
grant select on api.my_kyc, api.my_consents, api.my_recipients, api.audit_logs to authenticated;
grant select on api.legal_versions to anon, authenticated;
