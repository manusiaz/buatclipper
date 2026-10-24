-- Helper org (identik di admin/brand, disalin scripts/sync-fn-shared.sh): membaca org_members/org_links lokal (pemilik di
-- brand, replika di admin) dan ops.enqueue_notification versi project masing-masing.
-- Anggota langsung org (bukan lewat agency): dipakai aksi pengelolaan anggota & persetujuan tautan agency.
-- FOR SHARE: pemanggil yang sedang dikeluarkan/diturunkan oleh transaksi lain menunggu commit-nya lalu ditolak (R23-1),
-- bukan lolos memakai otoritas lama. Fungsi yang juga mengunci org (manage_team, update_org) mengunci org dulu dengan
-- FOR NO KEY UPDATE: tidak bentrok dengan KEY SHARE dari cek FK insert (undangan, anggota) → tanpa deadlock (R24-1).
create function market.is_direct_member(p_org uuid, p_user uuid, variadic p_roles market.org_role[] default '{}') returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from market.org_members m where m.org_id = p_org and m.user_id = p_user
                                         and (cardinality(p_roles) = 0 or m.role = any (p_roles))
     for share;
  return found;
end $$;

-- fn:notify_org — notifikasi ke anggota org (langsung + agency tertaut) dengan role tertentu (NULL/kosong = semua).
-- Dipakai invoice.issued, campaign.approved/rejected, managed.draft_ready, org.verified/rejected, budget.*, submission.pending_review.
-- Payload selalu ditambah org_id + org_name (template email identity & deep link brand.{domain}/[org]/…).
create function market.notify_org(p_org uuid, p_roles market.org_role[], p_event text, p_payload jsonb default '{}') returns int
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  n int := 0;
  body jsonb := coalesce(p_payload, '{}')
                || jsonb_build_object('org_id', p_org, 'org_name', (select o.name from market.organizations o where o.id = p_org));
begin
  for r in
    select m.user_id from market.org_members m
     where m.org_id = p_org and (coalesce(cardinality(p_roles), 0) = 0 or m.role = any (p_roles))
    union
    select m.user_id from market.org_links l join market.org_members m on m.org_id = l.agency_org_id
     where l.client_org_id = p_org and l.approved_at is not null and l.revoked_at is null
       and (coalesce(cardinality(p_roles), 0) = 0 or m.role = any (p_roles))
  loop
    perform ops.enqueue_notification(r.user_id, p_event, body);
    n := n + 1;
  end loop;
  return n;
end $$;
