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

grant select on api.my_kyc, api.my_consents to authenticated;
grant select on api.legal_versions to anon, authenticated;
