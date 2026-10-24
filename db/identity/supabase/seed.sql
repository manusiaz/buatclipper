-- Data awal identity: versi dokumen legal yang terbit (E-31). Idempoten. Isi dokumen = urusan legal; URL menunjuk
-- {domain}/legal/[doc] (apps/web). Lokal memakai host dev; produksi: ganti host saat Fase 0 lalu terbitkan versi baru.
insert into member.legal_versions (kind, version, published_at, url) values
  ('tos_clipper', '2026-10-19', '2026-10-19', 'https://clipper.localhost/legal/tos-clipper'),
  ('tos_brand', '2026-10-19', '2026-10-19', 'https://clipper.localhost/legal/tos-brand'),
  ('privacy', '2026-10-19', '2026-10-19', 'https://clipper.localhost/legal/privacy')
on conflict (kind, version) do nothing;
