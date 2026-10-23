# Endpoint DB admin

Isi: uang (ledger, pool, invoice, payout), claim, review & fraud, notifikasi, config; replika profil/org/campaign/submisi. Folder: `db/core`. Dibangkitkan `pnpm endpoints` dari DB yang jalan — jangan diedit tangan.

| | URL dasar |
|---|---|
| Produksi | `https://api.{DOMAIN}` |
| Lokal (dev-stack) | `http://127.0.0.1:55321` |

Header: `apikey: <publishable key DB ini>`; untuk user `Authorization: Bearer <JWT sesi identity>` (semua DB percaya issuer
identity yang sama); Data API memakai schema `api` (`Accept-Profile: api` untuk GET, `Content-Profile: api` untuk POST).

Health: `POST /rest/v1/rpc/health` (publishable key cukup) → antrean bus keluar per target + event terakhir per sumber.

## Baca: view (`GET /rest/v1/<view>`) — 45

| Endpoint | Boleh dibaca | Keterangan |
|---|---|---|
| `GET /rest/v1/admin_ledger` | user (JWT identity) | F-A08 ledger untuk back-office finance: entri + pemilik akun, hanya admin_finance (baris kosong untuk yang lain). |
| `GET /rest/v1/admin_profiles` | user (JWT identity) | Admin (F-A07): status & Trust Score semua clipper. |
| `GET /rest/v1/alerts` | user (JWT identity) |  |
| `GET /rest/v1/audit_logs` | user (JWT identity) |  |
| `GET /rest/v1/bank_lines` | user (JWT identity) |  |
| `GET /rest/v1/broadcasts` | user (JWT identity) |  |
| `GET /rest/v1/budget_alerts` | user (JWT identity) |  |
| `GET /rest/v1/campaign_assets` | anon, user (JWT identity) |  |
| `GET /rest/v1/campaign_invites` | user (JWT identity) |  |
| `GET /rest/v1/campaigns` | anon, user (JWT identity) | Publik (anon + login) |
| `GET /rest/v1/categories` | anon, user (JWT identity) |  |
| `GET /rest/v1/claims` | user (JWT identity) |  |
| `GET /rest/v1/clip_earnings` | user (JWT identity) |  |
| `GET /rest/v1/fee_rules` | anon, user (JWT identity) |  |
| `GET /rest/v1/fraud_flags` | user (JWT identity) |  |
| `GET /rest/v1/fulfillment_exports` | user (JWT identity) | Admin (A5.1): CSV penerima yang sudah diserahkan ke brand; pending = klaim yang masih menunggu kiriman brand (unduh ulang). |
| `GET /rest/v1/fulfillments` | user (JWT identity) |  |
| `GET /rest/v1/invoices` | user (JWT identity) |  |
| `GET /rest/v1/leaderboard` | user (JWT identity) |  |
| `GET /rest/v1/managed_briefs` | user (JWT identity) | Paket managed (J-A7): brief mentah brand untuk anggota org pemilik & admin; api.campaigns publik tidak membawanya. |
| `GET /rest/v1/my_profile` | user (JWT identity) | Login (baris dibatasi RLS: milik sendiri / anggota org / admin) |
| `GET /rest/v1/notification_prefs` | user (JWT identity) |  |
| `GET /rest/v1/notifications` | user (JWT identity) |  |
| `GET /rest/v1/org_links` | user (JWT identity) |  |
| `GET /rest/v1/org_members` | user (JWT identity) |  |
| `GET /rest/v1/org_refunds` | user (JWT identity) |  |
| `GET /rest/v1/organizations` | user (JWT identity) |  |
| `GET /rest/v1/payout_batches` | user (JWT identity) |  |
| `GET /rest/v1/payouts` | user (JWT identity) |  |
| `GET /rest/v1/profiles` | anon, user (JWT identity) |  |
| `GET /rest/v1/rate_rules` | anon, user (JWT identity) |  |
| `GET /rest/v1/referrals` | user (JWT identity) |  |
| `GET /rest/v1/report_links` | user (JWT identity) |  |
| `GET /rest/v1/review_decisions` | user (JWT identity) |  |
| `GET /rest/v1/reward_codes` | user (JWT identity) |  |
| `GET /rest/v1/reward_pools` | anon, user (JWT identity) |  |
| `GET /rest/v1/reward_types` | anon, user (JWT identity) |  |
| `GET /rest/v1/sanctions` | user (JWT identity) | §12 sanksi & bandingnya: clipper melihat miliknya (RLS), admin_moderator/admin_support semua. |
| `GET /rest/v1/score_events` | user (JWT identity) |  |
| `GET /rest/v1/settings` | anon, user (JWT identity) |  |
| `GET /rest/v1/social_accounts` | user (JWT identity) |  |
| `GET /rest/v1/submissions` | user (JWT identity) |  |
| `GET /rest/v1/view_snapshots` | user (JWT identity) |  |
| `GET /rest/v1/wallet_balances` | user (JWT identity) |  |
| `GET /rest/v1/wallet_entries` | user (JWT identity) |  |

## Aksi: RPC (`POST /rest/v1/rpc/<fungsi>`, body JSON = argumen) — 78

| Endpoint | Argumen | Boleh dipanggil | Keterangan |
|---|---|---|---|
| `POST /rest/v1/rpc/admin_overview` | `-` | user (JWT identity) | F-A01 overview admin (admin apa pun, aal2). |
| `POST /rest/v1/rpc/appeal_sanction` | `p_sanction uuid, p_message text` | user (JWT identity) | Clipper membanding sanksinya sendiri, sekali per sanksi; masuk antrean moderasi (tab Banding sanksi). |
| `POST /rest/v1/rpc/appeal_submission` | `p_submission uuid, p_message text` | user (JWT identity) | F-C07 banding 1× per submisi (unique index review_one_appeal_per_submission), S-03 rejected → appealed. |
| `POST /rest/v1/rpc/approve_payout_batch` | `p_batch uuid` | user (JWT identity) | Aturan dua orang: approved_by ≠ created_by ditegakkan constraint payout_batches_two_person (23514). |
| `POST /rest/v1/rpc/approve_refund` | `p_refund uuid` | user (JWT identity) | Persetujuan refund oleh admin_finance (aal2); dua orang: approved_by ≠ requested_by (constraint org_refunds_two_person). |
| `POST /rest/v1/rpc/attach_faktur` | `p_invoice uuid, p_faktur_no text, p_path text` | user (JWT identity) | B1.8 "unduh faktur setelah lunas": admin_finance mencatat nomor faktur pajak (diterbitkan di Coretax DJP) + PDF-nya yang sudah diunggah ke invoice-docs/{org_id}/{invoice_id}/…; brand_owner/brand_finance mengunduh lewat signed URL. |
| `POST /rest/v1/rpc/bank_issues` | `-` | user (JWT identity) |  |
| `POST /rest/v1/rpc/bridge_alert_notified` | `p_alert bigint` | server (secret key) | F-X01: email alert terkirim ke admin (bridge cron notify_admins sukses) → batas 1 email/jenis/jam mulai dihitung. |
| `POST /rest/v1/rpc/bridge_attach_export` | `p_batch uuid, p_file_ref text, p_held jsonb, p_exported uuid[]` | server (secret key) | Alur 3: CSV jadi. |
| `POST /rest/v1/rpc/bridge_attach_fulfillment_export` | `p_reward_type uuid, p_file_ref text, p_exported uuid[]` | server (secret key) | Serah-terima CSV penerima ke brand: klaim yang ada di berkas → processing + export_ref (tidak terekspor ulang; refund butuh konfirmasi brand). |
| `POST /rest/v1/rpc/bridge_attach_proof` | `p_target text, p_id uuid, p_proof_ref text` | server (secret key) | Alur 9: bukti transfer. |
| `POST /rest/v1/rpc/bridge_close_account` | `p_user uuid` | server (secret key) | Alur 7 (UU PDP): tutup akun dalam satu transaksi. |
| `POST /rest/v1/rpc/bridge_collect_ids` | `-` | server (secret key) | Alur 10: ID lintas DB yang dirujuk core (profil belum ditutup, rekening & penerima milik mereka). |
| `POST /rest/v1/rpc/bridge_fraud_device_params` | `-` | server (secret key) | FR-05 (§12 "semua ambang di config"): identity membaca jendela & minimum akun per perangkat sebelum scan sesi login. |
| `POST /rest/v1/rpc/bridge_fulfillment_export` | `p_reward_type uuid` | server (secret key) | Alur 3 (reward fisik/manual_export): klaim yang menunggu export ke brand. |
| `POST /rest/v1/rpc/bridge_fulfillment_export_accepted` | `p_reward_type uuid, p_file_ref text` | server (secret key) | Unduh ulang CSV penerima: identity hanya menandatangani berkas yang benar-benar diterima core untuk reward type itu. |
| `POST /rest/v1/rpc/bridge_get_batch` | `p_batch uuid` | server (secret key) | Alur 3: isi batch yang sudah disetujui dua orang (approved_by ≠ created_by) untuk dibuat CSV di identity. |
| `POST /rest/v1/rpc/bridge_get_payout` | `p_payout uuid` | server (secret key) | Alur 11: data payout instant untuk disburse (transfer = net_amount = amount − fee). |
| `POST /rest/v1/rpc/bridge_get_refund` | `p_refund uuid` | server (secret key) | AB-6: refund org perorangan → identity membuka rekening bank pribadi dest_set_by (pemilik org) untuk transfer. |
| `POST /rest/v1/rpc/bridge_mark_instant` | `p_payout uuid, p_status text, p_provider_ref text, p_error text` | server (secret key) | Alur 11: hasil penyedia disbursement. |
| `POST /rest/v1/rpc/bridge_pph21` | `p_from date, p_to date` | server (secret key) | Alur 9: rekap bruto payout terbayar per clipper (dasar PPh 21), rentang tanggal WIB inklusif. |
| `POST /rest/v1/rpc/bridge_raise_fraud_flag` | `p_target_type text, p_target_id uuid, p_signal text, p_score numeric, p_details jsonb` | server (secret key) | Alur 6: sinyal fraud dari identity (FR-04 NIK/rekening ganda, FR-05 device/IP sama). |
| `POST /rest/v1/rpc/bridge_refund_revealed` | `p_refund uuid, p_dest_set_by uuid` | server (secret key) | R26-1: rekening pribadi refund dibuka untuk transfer = transfer dimulai. |
| `POST /rest/v1/rpc/bridge_report_orphans` | `p_missing jsonb` | server (secret key) | Alur 10: ID yang tidak ada lagi di identity → alert antrean review finance. |
| `POST /rest/v1/rpc/bus_receive` | `p_source text, p_events jsonb` | server (secret key) | Dipanggil Edge Function bridge (service role) setelah HMAC sumber terverifikasi. |
| `POST /rest/v1/rpc/buy_pin` | `p_campaign uuid, p_days integer` | user (JWT identity) | REV-4 pin berbayar: invoice pinned (harga public.billing.pin_price_per_week_idr per minggu yang dimulai); pin_until diteruskan dari pin yang masih berjalan. |
| `POST /rest/v1/rpc/campaign_detail` | `p_campaign uuid` | user (JWT identity) | F-C04 detail campaign + status claim/submisi pemanggil + CTA (sama dengan list_campaigns & claim_campaign). |
| `POST /rest/v1/rpc/campaign_stats` | `p_campaign uuid` | user (JWT identity) | F-B05/F-B08 dashboard brand: angka laporan (market.campaign_report, sama dengan link read-only) + spend per pool, eCPM, utilisasi, proyeksi, kurva views harian (selisih antar snapshot, tanggal WIB). |
| `POST /rest/v1/rpc/cancel_fulfillment` | `p_fulfillment uuid, p_reason text, p_confirmed_not_delivered boolean` | user (JWT identity) | Batalkan/kembalikan klaim reward non-tunai (S-06): requested → on_hold → cancelled, on_hold → cancelled, processing → failed → returned, failed → returned. |
| `POST /rest/v1/rpc/cancel_payout` | `p_payout uuid, p_reason text` | user (JWT identity) | Batalkan payout yang ditahan (S-05 on_hold → cancelled; batch yang belum diekspor: requested → on_hold → cancelled) oleh admin_finance (aal2): dana + fee kembali ke Tersedia. |
| `POST /rest/v1/rpc/claim_campaign` | `p_campaign uuid` | user (JWT identity) | F-C05: claim = reservasi 1 slot submit, kedaluwarsa public.market.claim_hours (48). |
| `POST /rest/v1/rpc/confirm_invoice_payment` | `p_invoice uuid, p_amount numeric, p_paid_at timestamp with time zone, p_ref text, p_channel text` | user (JWT identity) |  |
| `POST /rest/v1/rpc/control_campaign` | `p_campaign uuid, p_action text, p_params jsonb` | user (JWT identity) | F-B06 kontrol campaign berjalan (S-01). |
| `POST /rest/v1/rpc/copy_campaign_economics` | `p_from uuid, p_to uuid` | user (JWT identity) | F-B10 bagian admin: isi disalin api.duplicate_campaign project brand (hasilnya draft baru); di sini pool & rule aktif ikut disalin (allocated 0) + override fee campaign. |
| `POST /rest/v1/rpc/create_payout_batch` | `p_cutoff timestamp with time zone` | user (JWT identity) |  |
| `POST /rest/v1/rpc/create_report_link` | `p_campaign uuid, p_days integer` | user (JWT identity) | F-B09: link laporan read-only. |
| `POST /rest/v1/rpc/decide_sanction_appeal` | `p_sanction uuid, p_decision text, p_note text` | user (JWT identity) | admin_moderator memutus banding. |
| `POST /rest/v1/rpc/health` | `-` | anon, user (JWT identity), server (secret key) | Endpoint health tiap project (POST /rest/v1/rpc/health): antrean keluar per target + event terakhir yang diterima per sumber. |
| `POST /rest/v1/rpc/hold_payout` | `p_payout uuid, p_reason text` | user (JWT identity) | admin_finance: tahan payout mencurigakan tanpa mengembalikan dana (dibatalkan/dilepas setelah review). |
| `POST /rest/v1/rpc/import_bank_lines` | `p_lines jsonb` | user (JWT identity) | p_lines: [{date: 'YYYY-MM-DD', amount: ±nominal, reference, description}] dari CSV (parser app), maks 5.000 baris per unggahan. |
| `POST /rest/v1/rpc/list_campaigns` | `p_filters jsonb, p_cursor text` | anon, user (JWT identity) | F-C03 daftar campaign untuk anon (landing, cta NULL) dan clipper login (cta_state + alasan per user). |
| `POST /rest/v1/rpc/manage_org` | `p_org uuid, p_action text, p_params jsonb` | user (JWT identity) | F-A07 admin_super/admin_ops aal2: set_fee {mgmt_fee_pct, admin_fee_pct, clipper_fee_pct, instant_withdraw_fee} atau null untuk kembali ke global. |
| `POST /rest/v1/rpc/manage_user` | `p_user uuid, p_action text, p_params jsonb` | user (JWT identity) | F-A07 admin (admin_ops/admin_moderator aal2) atas clipper: trust_override {delta, note} (E-40 admin_override; skor dihitung ulang langsung, rumus = job trust-score) / suspend {days 1–365, reason} / unsuspend {note} / ban {reason} / unban… |
| `POST /rest/v1/rpc/mark_batch_paid` | `p_batch uuid, p_results jsonb` | user (JWT identity) | p_results: [{payout_id, status: paid/failed, bank_ref, reason?}] (reason → payouts.last_error). |
| `POST /rest/v1/rpc/mark_fulfillment_delivered` | `p_fulfillment uuid, p_ref text` | user (JWT identity) | F-A10 tandai terkirim: reward manual_export (barang fisik/voucher yang dikirim brand di luar sistem) ditutup admin_ops (aal2) dengan referensi kiriman (resi/nomor voucher). |
| `POST /rest/v1/rpc/missing_brief_tags` | `p_campaign uuid, p_caption text` | user (JWT identity), server (secret key) | Cek caption terhadap brief (F-C06, §11): mengembalikan yang kurang, mis. |
| `POST /rest/v1/rpc/my_clip_terms` | `-` | user (JWT identity) | Cap & hold yang berlaku untuk clipper ini per platform (finance.clip_terms, satu sumber dengan accrual & release): {platform: {cap_pct, hold_days}} untuk cap efektif di detail campaign dan perkiraan tanggal Tersedia. |
| `POST /rest/v1/rpc/my_referral_code` | `-` | user (JWT identity) | Kode referral milik sendiri; dibuat saat pertama diminta. |
| `POST /rest/v1/rpc/my_stats` | `-` | user (JWT identity) | F-C12 profil clipper: total views valid, klip, approval rate (approved ÷ diputus; yang menunggu/banding tidak dihitung), earning per reward type per bucket S-04 dari ledger, Trust Score. |
| `POST /rest/v1/rpc/org_credit` | `p_org uuid` | user (JWT identity) |  |
| `POST /rest/v1/rpc/pay_invoice_with_credit` | `p_invoice uuid, p_amount numeric` | user (JWT identity) |  |
| `POST /rest/v1/rpc/record_review` | `p_target_type text, p_target_id uuid, p_decision text, p_reason text, p_message text, p_note text` | user (JWT identity) | Keputusan review. |
| `POST /rest/v1/rpc/record_sanction_appeal` | `p_sanction uuid, p_message text` | user (JWT identity) | Clipper yang login-nya diblokir (ban / suspend login) membanding lewat bantuan; admin_support mencatatnya. |
| `POST /rest/v1/rpc/release_payout` | `p_payout uuid, p_note text` | user (JWT identity) | Lepas tahan setelah review: on_hold → requested (antre batch berikutnya). |
| `POST /rest/v1/rpc/report_by_token` | `p_token text` | anon, user (JWT identity) |  |
| `POST /rest/v1/rpc/request_fulfillment` | `p_reward_type uuid, p_amount numeric, p_recipient jsonb, p_recipient_ref uuid, p_idempotency text` | user (JWT identity) | Klaim reward non-tunai. |
| `POST /rest/v1/rpc/request_payout` | `p_method uuid, p_amount numeric, p_channel text, p_idempotency text` | user (JWT identity) |  |
| `POST /rest/v1/rpc/request_refund` | `p_org uuid, p_campaign uuid, p_mode text, p_amount numeric, p_idempotency text` | user (JWT identity) | Sisa budget creator (D-09, F-B04). |
| `POST /rest/v1/rpc/reset_social_account` | `p_account uuid, p_note text` | user (JWT identity) | §4 admin_support "reset koneksi akun": event social.reset ke project creator (pemilik akun & token: Vault dihapus, status revoked, tracking berhenti, clipper dikabari untuk menyambung ulang akun yang sama). |
| `POST /rest/v1/rpc/resolve_alert` | `p_id bigint` | user (JWT identity) |  |
| `POST /rest/v1/rpc/resolve_bank_line` | `p_id bigint, p_note text` | user (JWT identity) | Baris bank yang bukan transaksi sistem (biaya bank, bunga, setoran QRIS gabungan) ditutup dengan catatan; tercatat di audit. |
| `POST /rest/v1/rpc/resolve_fraud_flag` | `p_flag uuid, p_action text, p_note text` | user (JWT identity) | Sanksi bertingkat (§12): hold (tahan earning/payout), reverse (earning pending kembali ke pool + submisi hangus), suspend 30 hari, ban (permanen + pending hangus + ban Auth di identity lewat bridge), dismiss. |
| `POST /rest/v1/rpc/retry_fulfillment` | `p_fulfillment uuid` | user (JWT identity) | C6.2 / J-A5: webhook yang berhenti setelah 12× gagal dikirim ulang setelah brand memperbaiki endpoint-nya (admin_ops). |
| `POST /rest/v1/rpc/revoke_report_link` | `p_link uuid` | user (JWT identity) |  |
| `POST /rest/v1/rpc/save_campaign` | `p_campaign jsonb, p_submit boolean` | user (JWT identity) | F-B02/F-A03 builder, bagian admin. |
| `POST /rest/v1/rpc/save_reward_type` | `p jsonb` | user (JWT identity) | F-B03 reward type custom milik org. |
| `POST /rest/v1/rpc/send_broadcast` | `p_title text, p_body text, p_segment jsonb, p_channels text[], p_scheduled_at timestamp with time zone, p_kind text` | user (JWT identity) | A6.1: jadwalkan broadcast; dikirim job broadcast-dispatch (ops.dispatch_broadcasts). |
| `POST /rest/v1/rpc/set_bank_ref` | `p_target text, p_id uuid, p_ref text, p_note text` | user (JWT identity) | Referensi mutasi bank pada transaksi sistem: refund diisi sebelum bukti transfer diunggah (pay_refund mewajibkannya); payout batch / invoice yang referensinya salah ketik dikoreksi dengan catatan. |
| `POST /rest/v1/rpc/set_refund_dest` | `p_refund uuid, p_dest jsonb` | user (JWT identity) | AB-6: rekening tujuan refund diisi brand_owner/brand_finance (aal2) selama refund belum disetujui, termasuk refund yang dibuat otomatis saat campaign dibatalkan. |
| `POST /rest/v1/rpc/update_config` | `p_key text, p_value jsonb` | user (JWT identity) | Config admin (F-A04, F-A09, F-A11) & broadcast (F-A12). |
| `POST /rest/v1/rpc/upload_reward_codes` | `p_reward_type uuid, p_codes text[]` | user (JWT identity) | F-B03 pool kode voucher: hanya reward type code_pool milik org pemanggil; kode duplikat diabaikan (unique). |
| `POST /rest/v1/rpc/worker_ack` | `p_queue text, p_msg_id bigint` | server (secret key) |  |
| `POST /rest/v1/rpc/worker_assign_code` | `p_fulfillment uuid` | server (secret key) | Pasang satu kode dari pool (idempoten: kode yang sudah terpasang dikembalikan lagi). |
| `POST /rest/v1/rpc/worker_dequeue` | `p_queue text, p_qty integer, p_vt_seconds integer` | server (secret key) | ---------- queue (Supabase Queues) ---------- |
| `POST /rest/v1/rpc/worker_fulfillment_result` | `p_fulfillment uuid, p_ok boolean, p_ref text, p_error text` | server (secret key) | Hasil kirim: sukses → delivered + notifikasi; gagal → coba lagi 5 menit, setelah 12 percobaan → on_hold + alert. |
| `POST /rest/v1/rpc/worker_fulfillments_due` | `p_limit integer` | server (secret key) | ---------- fulfillment non-tunai (worker fulfill, F-B03, S-06) ---------- Status tetap requested selama percobaan ulang (S-06 tidak punya processing → on_hold); processing → delivered hanya saat sukses. |
| `POST /rest/v1/rpc/worker_notification` | `p_id bigint` | server (secret key) | ---------- notifikasi (worker notify, alur 4) ---------- |
| `POST /rest/v1/rpc/worker_unsubscribe` | `p_user uuid` | server (secret key) | One-click unsubscribe email promosi (List-Unsubscribe-Post); email transaksional tetap jalan. |

## Edge Function (`/functions/v1/<nama>`) — 3

| Endpoint | Keterangan |
|---|---|
| `/functions/v1/bridge` | lihat handler.ts. verify_jwt = false: HMAC (identity) atau apikey (pg_cron) dicek di kode. |
| `/functions/v1/fulfill` | dipicu pg_cron (fulfillment-retry, tiap 5 menit) dengan header apikey = secret key core. |
| `/functions/v1/notify` | POST (pg_cron notify-drain, header apikey) menguras queue email; |
