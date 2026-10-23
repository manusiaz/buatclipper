# Endpoint DB identity

Isi: akun, login, PII (KYC, rekening), consent, push. Folder: `db/identity`. Dibangkitkan `pnpm endpoints` dari DB yang jalan — jangan diedit tangan.

| | URL dasar |
|---|---|
| Produksi | `https://auth.{DOMAIN}` |
| Lokal (dev-stack) | `http://127.0.0.1:54321` |

Header: `apikey: <publishable key DB ini>`; untuk user `Authorization: Bearer <JWT sesi identity>` (semua DB percaya issuer
identity yang sama); Data API memakai schema `api` (`Accept-Profile: api` untuk GET, `Content-Profile: api` untuk POST).

Health: `GET /auth/v1/health` (GoTrue).

## Baca: view (`GET /rest/v1/<view>`) — 6

| Endpoint | Boleh dibaca | Keterangan |
|---|---|---|
| `GET /rest/v1/audit_logs` | user (JWT identity) | F-A11: audit log identity (KYC, role, ekspor PII) untuk admin_super; baris dibatasi RLS audit_logs_super_read. |
| `GET /rest/v1/legal_versions` | anon, user (JWT identity) |  |
| `GET /rest/v1/my_consents` | user (JWT identity) |  |
| `GET /rest/v1/my_kyc` | user (JWT identity) | View yang boleh dibaca browser. |
| `GET /rest/v1/my_recipients` | user (JWT identity) | Data penerima reward milik sendiri (isi terenkripsi tidak ikut): app clipper memakai id-nya sebagai recipient_ref klaim. |
| `GET /rest/v1/push_subscriptions` | user (JWT identity) |  |

## Aksi: RPC (`POST /rest/v1/rpc/<fungsi>`, body JSON = argumen) — 34

| Endpoint | Argumen | Boleh dipanggil | Keterangan |
|---|---|---|---|
| `POST /rest/v1/rpc/admin_kyc_decision` | `p_user_id uuid, p_decision text, p_reason text` | user (JWT identity) | Reviewer KYC (admin_moderator, aal2) menyetujui/menolak KYC yang menunggu. |
| `POST /rest/v1/rpc/admin_kyc_queue` | `p_status text, p_limit integer` | user (JWT identity) | F-A07 antrean KYC (admin_moderator aal2). |
| `POST /rest/v1/rpc/admin_list_roles` | `-` | user (JWT identity) | F-A07 daftar admin (admin_super aal2): siapa memegang role apa. |
| `POST /rest/v1/rpc/admin_read` | `p_user_id uuid` | user (JWT identity) | Admin membaca KYC + rekening tersamar satu user. |
| `POST /rest/v1/rpc/admin_set_role` | `p_user_id uuid, p_role text, p_grant boolean` | user (JWT identity) | admin_super (aal2) memberi/mencabut role platform E-27. |
| `POST /rest/v1/rpc/my_payout_methods` | `-` | user (JWT identity) | Rekening tersamar milik sendiri (withdraw, alur 8): hanya last4 + bank + nama, tidak pernah nomor lengkap. |
| `POST /rest/v1/rpc/record_consent` | `p_kind text, p_version text, p_granted boolean` | user (JWT identity) | Catat atau cabut consent milik sendiri (E-28). |
| `POST /rest/v1/rpc/save_activity_token` | `p_token text, p_kind text, p_ref text` | user (JWT identity) | Live Activity iOS: token push-to-start perangkat (apns_start, tanpa p_ref) atau token update satu activity (apns_activity, p_ref = id payout). |
| `POST /rest/v1/rpc/save_expo_push_token` | `p_token text` | user (JWT identity) | App native (Android/iOS): token Expo push perangkat ini. |
| `POST /rest/v1/rpc/save_push_subscription` | `p_endpoint text, p_p256dh text, p_auth text` | user (JWT identity) | Simpan langganan perangkat ini untuk user sekarang. |
| `POST /rest/v1/rpc/shared_device_groups` | `p_since interval, p_min_accounts integer` | server (secret key) | FR-05: grup sesi dari IP + user agent yang sama dengan ≥ p_min_accounts akun berbeda. |
| `POST /rest/v1/rpc/store_kyc` | `p_user_id uuid, p_nik_hash bytea, p_nik_enc bytea, p_nik_last4 text, p_key_version smallint, p_legal_name text, p_doc_ref text` | server (secret key) |  |
| `POST /rest/v1/rpc/store_payout_method` | `p_user_id uuid, p_kind text, p_bank_code text, p_account_no_hash bytea, p_account_no_enc bytea, p_last4 text, p_key_version smallint, p_account_name text` | server (secret key) |  |
| `POST /rest/v1/rpc/store_recipient` | `p_user_id uuid, p_reward_type_id uuid, p_data_enc bytea, p_key_version smallint` | server (secret key) |  |
| `POST /rest/v1/rpc/svc_add_push_tickets` | `p_endpoints text[], p_tickets text[]` | server (secret key) | Ticket Expo yang diterima (pasangan endpoint[i] ↔ ticket[i]); token yang sudah dihapus dilewati. |
| `POST /rest/v1/rpc/svc_admin_ids` | `p_roles text[]` | server (secret key) | F-X01 admin: penerima email alert operasional = admin dengan salah satu role ini. |
| `POST /rest/v1/rpc/svc_audit` | `p_actor uuid, p_action text, p_target text, p_after jsonb` | server (secret key) | Jejak akses PII oleh Edge Function (export CSV, unggah bukti, unduh data sendiri, aksi Auth admin) ke E-24 identity. |
| `POST /rest/v1/rpc/svc_check_ids` | `p_user_ids uuid[], p_method_ids uuid[], p_recipient_refs uuid[]` | server (secret key) | Rekonsiliasi ID lintas DB (alur 10). |
| `POST /rest/v1/rpc/svc_close_member` | `p_user uuid, p_blocked boolean, p_retain_until date` | server (secret key) | Hapus akun (alur 7), dipanggil delete-account SETELAH core close_account sukses dan SEBELUM auth.admin.deleteUser. |
| `POST /rest/v1/rpc/svc_create_handoff` | `p_user uuid, p_code_hash bytea, p_next text` | server (secret key) | Handoff sesi app native → web (session-handoff create): kode baru berlaku 60 detik; maks 10 kode belum kedaluwarsa per user (54000). |
| `POST /rest/v1/rpc/svc_delete_push` | `p_endpoint text` | server (secret key) |  |
| `POST /rest/v1/rpc/svc_due_push_tickets` | `p_limit integer` | server (secret key) | job:push-receipts: ticket ≥ 15 menit (receipt Expo sudah siap), terlama dulu. |
| `POST /rest/v1/rpc/svc_has_consent` | `p_user uuid, p_kind text` | server (secret key) | Consent aktif. |
| `POST /rest/v1/rpc/svc_hash_holder` | `p_nik_hash bytea, p_bank_code text, p_account_hash bytea` | server (secret key) | FR-04: pemegang NIK / rekening yang dicoba dipakai ulang akun lain (payload fraud flag). |
| `POST /rest/v1/rpc/svc_kyc` | `p_user_ids uuid[]` | server (secret key) | KYC per user. |
| `POST /rest/v1/rpc/svc_my_data` | `p_user uuid` | server (secret key) | Unduh data saya (C2.4): semua baris identity milik user, ciphertext ikut (member-data yang mendekripsi). |
| `POST /rest/v1/rpc/svc_payout_methods` | `p_ids uuid[]` | server (secret key) | Rekening untuk CSV payout (alur 3) dan disburse (alur 11). |
| `POST /rest/v1/rpc/svc_platform_roles` | `p_user uuid` | server (secret key) | Role platform target (admin-auth: moderator tidak boleh mem-ban akun admin). |
| `POST /rest/v1/rpc/svc_push_subscriptions` | `p_user uuid` | server (secret key) | Push (alur 4): langganan per user (web push, token Expo, token Live Activity APNs), buang endpoint/token mati, catat terakhir dipakai. |
| `POST /rest/v1/rpc/svc_recipients` | `p_ids uuid[]` | server (secret key) | Data penerima reward (E-29) untuk export fulfillment (pola alur 3, syarat consent share_with_brand). |
| `POST /rest/v1/rpc/svc_redeem_handoff` | `p_code_hash bytea` | server (secret key) | Tukar kode (session-handoff redeem): sekali pakai & belum kedaluwarsa, atomik; kosong = tidak sah. |
| `POST /rest/v1/rpc/svc_resolve_push_tickets` | `p_tickets text[], p_dead_endpoints text[]` | server (secret key) | Hasil receipt: ticket yang sudah terbaca dihapus, token DeviceNotRegistered dihapus (ticket-nya ikut cascade), ticket > 24 jam dibuang (receipt Expo sudah kedaluwarsa). |
| `POST /rest/v1/rpc/svc_touch_push` | `p_endpoint text` | server (secret key) |  |
| `POST /rest/v1/rpc/svc_user_payout_methods` | `p_user uuid` | server (secret key) | AB-6 refund org perorangan: rekening bank aktif milik pemilik org, terbaru dulu (pii-export memilih yang lolos cek KYC). |

## Edge Function (`/functions/v1/<nama>`) — 7

| Endpoint | Keterangan |
|---|---|
| `/functions/v1/admin-auth` | Edge Function entrypoint (verify_jwt = false; admin JWT aal2 verified in code). |
| `/functions/v1/bridge` | Edge Function entrypoint (verify_jwt = false; HMAC from core or apikey from pg_cron). |
| `/functions/v1/delete-account` | Edge Function entrypoint (verify_jwt = false; user JWT verified in code). |
| `/functions/v1/disburse` | provider webhook for instant withdraw (alur 11): POST /disburse/callback, header x-callback-token. |
| `/functions/v1/member-data` | Edge Function entrypoint (verify_jwt = false; the user JWT is verified in code via JWKS). |
| `/functions/v1/pii-export` | Edge Function entrypoint (verify_jwt = false; admin JWT aal2 verified in code). |
| `/functions/v1/session-handoff` | Edge Function entrypoint (verify_jwt = false; create: JWT user diverifikasi di kode lewat |
