# Endpoint DB brand

Isi: org, tim, undangan, agency, isi campaign + aset/cover. Folder: `db/brand`. Dibangkitkan `pnpm endpoints` dari DB yang jalan — jangan diedit tangan.

| | URL dasar |
|---|---|
| Produksi | `https://brand-api.{DOMAIN}` |
| Lokal (dev-stack) | `http://127.0.0.1:57321` |

Header: `apikey: <publishable key DB ini>`; untuk user `Authorization: Bearer <JWT sesi identity>` (semua DB percaya issuer
identity yang sama); Data API memakai schema `api` (`Accept-Profile: api` untuk GET, `Content-Profile: api` untuk POST).

Health: `POST /rest/v1/rpc/health` (publishable key cukup) → antrean bus keluar per target + event terakhir per sumber.

## Baca: view (`GET /rest/v1/<view>`) — 10

| Endpoint | Boleh dibaca | Keterangan |
|---|---|---|
| `GET /rest/v1/campaign_assets` | anon, user (JWT identity) |  |
| `GET /rest/v1/campaign_invites` | user (JWT identity) |  |
| `GET /rest/v1/campaigns` | anon, user (JWT identity) | Campaign (isi milik brand + status/jadwal replika admin). |
| `GET /rest/v1/categories` | anon, user (JWT identity) |  |
| `GET /rest/v1/managed_briefs` | user (JWT identity) |  |
| `GET /rest/v1/org_invites` | user (JWT identity) |  |
| `GET /rest/v1/org_links` | user (JWT identity) |  |
| `GET /rest/v1/org_members` | user (JWT identity) |  |
| `GET /rest/v1/organizations` | user (JWT identity) | View Data API brand (security_invoker: RLS tabel berlaku). |
| `GET /rest/v1/profiles` | anon, user (JWT identity) |  |

## Aksi: RPC (`POST /rest/v1/rpc/<fungsi>`, body JSON = argumen) — 13

| Endpoint | Argumen | Boleh dipanggil | Keterangan |
|---|---|---|---|
| `POST /rest/v1/rpc/accept_org_invite` | `p_token text` | user (JWT identity) | B2.2: terima undangan → profil dibuat dulu kalau belum ada → E-03. |
| `POST /rest/v1/rpc/bus_receive` | `p_source text, p_events jsonb` | server (secret key) | Dipanggil Edge Function bridge (service role) setelah HMAC sumber terverifikasi. |
| `POST /rest/v1/rpc/create_org` | `p_name text, p_org_type text, p_legal_name text, p_npwp text, p_address text, p_is_agency boolean` | user (JWT identity) | B1.4: org baru pending_verification, pembuat = brand_owner. |
| `POST /rest/v1/rpc/create_org_invite` | `p_org uuid, p_role text` | user (JWT identity) | B2.1: link undangan anggota (berlaku 7 hari). |
| `POST /rest/v1/rpc/duplicate_campaign` | `p_campaign uuid, p_as_template boolean` | user (JWT identity) | F-B10: salinan isi selalu draft (tanpa jadwal, pin, aset). |
| `POST /rest/v1/rpc/health` | `-` | anon, user (JWT identity), server (secret key) | Endpoint health tiap project (POST /rest/v1/rpc/health): antrean keluar per target + event terakhir yang diterima per sumber. |
| `POST /rest/v1/rpc/invite_preview` | `p_token text` | anon, user (JWT identity) | Halaman undangan accounts (sebelum & sesudah login): token = kapabilitas, jadi pemegang link boleh melihat org + peran. |
| `POST /rest/v1/rpc/invite_to_campaign` | `p_campaign uuid, p_usernames text[]` | user (JWT identity) | F-B11: undang clipper (username) ke campaign; campaign visibility invite hanya terlihat yang diundang (RLS). |
| `POST /rest/v1/rpc/link_agency` | `p_agency uuid, p_client uuid, p_action text` | user (JWT identity) | F-B12 tautan agency → org klien. |
| `POST /rest/v1/rpc/manage_org` | `p_org uuid, p_action text, p_params jsonb` | user (JWT identity) | F-A07 admin (admin_ops aal2): verify / reject {reason, message, note} / suspend {reason} / add_member {user_id, role, username?, display_name?} (paket managed: user diundang dulu lewat Edge Function identity admin-auth, lalu ditulis di s… |
| `POST /rest/v1/rpc/manage_team` | `p_org uuid, p_action text, p_target uuid, p_role text` | user (JWT identity) | B2 (policy:core.org-role "owner kelola member"): brand_owner langsung mengubah role, mengeluarkan anggota, atau mencabut undangan yang belum dipakai. |
| `POST /rest/v1/rpc/save_campaign` | `p_campaign jsonb` | user (JWT identity) | F-B02/F-A03 isi campaign. |
| `POST /rest/v1/rpc/update_org` | `p_org uuid, p_name text, p_legal_name text, p_npwp text, p_address text` | user (JWT identity) | B1.5 cabang ditolak / F-B01: brand_owner memperbaiki data org. |

## Edge Function (`/functions/v1/<nama>`) — 1

| Endpoint | Keterangan |
|---|---|
| `/functions/v1/bridge` | event bus masuk dari project lain (x-bridge-from + HMAC per pengirim, lihat _shared/bus.ts). |
