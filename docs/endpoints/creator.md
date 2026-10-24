# Endpoint DB creator

Isi: profil & avatar, akun sosmed + token, submisi, snapshot views, Edge Function sosmed. Folder: `db/creator`. Dibangkitkan `pnpm endpoints` dari DB yang jalan — jangan diedit tangan.

| | URL dasar |
|---|---|
| Produksi | `https://creator-api.{DOMAIN}` |
| Lokal (dev-stack) | `http://127.0.0.1:56321` |

Header: `apikey: <publishable key DB ini>`; untuk user `Authorization: Bearer <JWT sesi identity>` (semua DB percaya issuer
identity yang sama); Data API memakai schema `api` (`Accept-Profile: api` untuk GET, `Content-Profile: api` untuk POST).

Health: `POST /rest/v1/rpc/health` (publishable key cukup) → antrean bus keluar per target + event terakhir per sumber.

## Baca: view (`GET /rest/v1/<view>`) — 4

| Endpoint | Boleh dibaca | Keterangan |
|---|---|---|
| `GET /rest/v1/claims` | user (JWT identity) | Claim milik sendiri (replika admin): Edge Function creator/social memeriksa claim sebelum daftar video. |
| `GET /rest/v1/my_profile` | user (JWT identity) |  |
| `GET /rest/v1/profiles` | anon, user (JWT identity) | View Data API creator (security_invoker: RLS tabel berlaku). |
| `GET /rest/v1/settings` | anon, user (JWT identity) | Config replika admin; kunci public.* terbaca semua (flag platform untuk Edge Function social/track-worker). |

## Aksi: RPC (`POST /rest/v1/rpc/<fungsi>`, body JSON = argumen) — 17

| Endpoint | Argumen | Boleh dipanggil | Keterangan |
|---|---|---|---|
| `POST /rest/v1/rpc/bus_receive` | `p_source text, p_events jsonb` | server (secret key) | Dipanggil Edge Function bridge (service role) setelah HMAC sumber terverifikasi. |
| `POST /rest/v1/rpc/ensure_profile` | `p_username text, p_display_name text, p_referral_code text, p_avatar_path text` | user (JWT identity) | Alur 1: buat profil E-01 dari JWT identity, atau perbarui username & nama tampilan kalau sudah ada (profil anggota brand dibuat lebih dulu lewat event profile.ensure, alur 5). |
| `POST /rest/v1/rpc/health` | `-` | anon, user (JWT identity), server (secret key) | Endpoint health tiap project (POST /rest/v1/rpc/health): antrean keluar per target + event terakhir yang diterima per sumber. |
| `POST /rest/v1/rpc/missing_brief_tags` | `p_campaign uuid, p_caption text` | server (secret key) | Cek caption terhadap brief (F-C06, §11): mengembalikan yang kurang, mis. |
| `POST /rest/v1/rpc/store_social_token` | `p_account_id uuid, p_token text` | server (secret key) | vault.social-tokens: token OAuth sosmed disimpan di Supabase Vault creator, tidak pernah plaintext di tabel. |
| `POST /rest/v1/rpc/worker_account_status` | `p_account uuid, p_status text` | server (secret key) | Status token akun sosmed: expired/revoked → tracking submisinya berhenti (enqueue hanya akun verified) + notifikasi sekali; verified (reconnect) → polling lanjut, views kumulatif tetap terhitung selama dalam view window. |
| `POST /rest/v1/rpc/worker_account_token` | `p_account uuid` | server (secret key) | Akun sosmed + token Vault (creator/social: daftar video & submit atas nama akun itu). |
| `POST /rest/v1/rpc/worker_accounts_to_refresh` | `p_within interval` | server (secret key) | Token yang kedaluwarsa dalam p_within (JSON Vault berisi expires_at). |
| `POST /rest/v1/rpc/worker_ack` | `p_queue text, p_msg_id bigint` | server (secret key) |  |
| `POST /rest/v1/rpc/worker_create_submission` | `p_user uuid, p_claim uuid, p_account uuid, p_post_id text, p_url text, p_posted_at timestamp with time zone, p_caption text, p_duration_sec integer, p_cover_hash bigint` | server (secret key) | Submit video (E-12, F-C06) setelah creator/social memverifikasi kepemilikan lewat API platform. |
| `POST /rest/v1/rpc/worker_defer` | `p_submission uuid, p_until timestamp with time zone` | server (secret key) | Poll dilewati (mis. |
| `POST /rest/v1/rpc/worker_dequeue` | `p_queue text, p_qty integer, p_vt_seconds integer` | server (secret key) |  |
| `POST /rest/v1/rpc/worker_post_gone` | `p_submission uuid, p_reason text` | server (secret key) | Post dihapus/diprivate sebelum lock (§11, FR-06): admin menghanguskan earning pending + notifikasi (event submission.post_gone). |
| `POST /rest/v1/rpc/worker_record_snapshot` | `p_submission uuid, p_views bigint, p_likes bigint, p_comments bigint, p_shares bigint, p_caption text, p_raw jsonb, p_extra jsonb` | server (secret key) | Satu snapshot dari worker (API sukses; error/rate limit tidak pernah dipanggil ke sini, §11). |
| `POST /rest/v1/rpc/worker_retry_later` | `p_queue text, p_msg_id bigint, p_seconds integer, p_submission uuid` | server (secret key) | §11: API error / rate limit → coba lagi dengan backoff (bukan visibility timeout tetap). |
| `POST /rest/v1/rpc/worker_submission_context` | `p_submission uuid` | server (secret key) |  |
| `POST /rest/v1/rpc/worker_upsert_social_account` | `p_user uuid, p_platform text, p_external_id text, p_handle text, p_followers integer, p_platform_created_at timestamp with time zone, p_token text` | server (secret key) | Connect OAuth (F-C02): satu akun sosmed = satu clipper selamanya (social_taken); batas 3 akun/platform dari trigger. |

## Edge Function (`/functions/v1/<nama>`) — 4

| Endpoint | Keterangan |
|---|---|
| `/functions/v1/bridge` | event bus masuk dari project lain (x-bridge-from + HMAC per pengirim, lihat _shared/bus.ts). |
| `/functions/v1/refresh-tokens` | dipicu pg_cron (job token-refresh, tiap 6 jam) dengan header apikey = secret key creator. |
| `/functions/v1/social` | lihat handler.ts. verify_jwt = false: JWT identity diverifikasi di kode (PRD §15.6). |
| `/functions/v1/track-worker` | dipicu pg_cron tiap 5 menit lewat ops.invoke_function (header apikey = secret key creator). |
