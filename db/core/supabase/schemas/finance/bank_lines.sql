-- F-A08 / A3.5 / §16 Uang: mutasi rekening bank (CSV internet banking, diunggah admin_finance) direkonsiliasi dengan kas sistem
-- per nomor referensi: total mutasi bank per referensi = total kas sistem per referensi (invoice lunas +paid_amount, payout
-- batch dibayar −(amount − fee), refund dibayar −(amount − transfer_fee)). Satu referensi boleh satu baris per payout atau satu
-- baris untuk seluruh batch. Baris yang bukan transaksi sistem (biaya admin bank, bunga, settlement QRIS) ditutup manual + catatan.
create table finance.bank_lines (
  id bigint generated always as identity primary key,
  value_date date not null,
  amount numeric(18, 2) not null check (amount <> 0),  -- + kredit (masuk), − debit (keluar)
  reference text not null check (reference ~ '\S' and length(reference) <= 120),
  description text not null default '' check (length(description) <= 500),
  line_hash text not null unique,  -- unggah ulang file yang sama tidak menggandakan baris
  status text not null default 'open' check (status in ('open', 'matched', 'manual')),
  note text check (length(note) between 3 and 500),
  imported_by uuid not null,
  imported_at timestamptz not null default now(),
  resolved_by uuid,
  resolved_at timestamptz,
  constraint bank_lines_manual check ((status = 'manual') = (note is not null and resolved_by is not null and resolved_at is not null))
);
create index bank_lines_reference_idx on finance.bank_lines (reference);
create index bank_lines_open_idx on finance.bank_lines (value_date) where status = 'open';

alter table finance.bank_lines enable row level security;
create policy bank_lines_iss on finance.bank_lines as restrictive for all to authenticated  -- policy:core.iss-identity
  using ((select ops.iss_ok())) with check ((select ops.iss_ok()));
create policy bank_lines_finance_read on finance.bank_lines for select to authenticated  -- policy:core.admin-aal2
  using ((select ops.has_admin('admin_finance')));
grant select on finance.bank_lines to authenticated;

create view api.bank_lines with (security_invoker = true) as
  select id, value_date, amount, reference, description, status, note, imported_at, resolved_at from finance.bank_lines;
grant select on api.bank_lines to authenticated;

-- Selisih saat ini (tanpa efek samping; tab Mutasi bank membacanya langsung): referensi bank yang tidak cocok, dan kas sistem
-- bertanggal di rentang mutasi yang sudah diunggah tanpa satu pun baris bank (referensi kosong juga). Invoice QRIS tidak dicek
-- "tanpa mutasi" (acquirer menyetor gabungan, bukan per invoice).
create function finance.bank_issues() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  first_day date;
  last_day date;
begin
  select min(b.value_date), max(b.value_date) into first_day, last_day from finance.bank_lines b;
  if first_day is null then
    return '{}';
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'bank_unmatched', (select jsonb_agg(b.id order by b.id) from finance.bank_lines b where b.status = 'open'),
    'missing_in_bank', (select jsonb_agg(x.k order by x.k) from (
        select 'invoice:' || i.id k, i.payment_ref ref from finance.invoices i
         where i.status = 'paid' and i.payment_channel = 'transfer' and (i.paid_at at time zone 'Asia/Jakarta')::date between first_day and last_day
        union all
        select 'payout:' || p.id, p.bank_ref from finance.payouts p
         where p.status = 'paid' and p.channel = 'batch' and (p.paid_at at time zone 'Asia/Jakarta')::date between first_day and last_day
        union all
        select 'refund:' || r.id, r.bank_ref from finance.org_refunds r
         where r.status = 'paid' and (r.paid_at at time zone 'Asia/Jakarta')::date between first_day and last_day) x
      where x.ref is null or not exists (select 1 from finance.bank_lines b where b.reference = x.ref))));
end $$;

-- Cocokkan semua baris (status open/matched dihitung ulang: payout yang belakangan gagal membuka lagi barisnya), lalu selisih
-- → alert reconcile.bank hanya bila ada selisih yang belum termuat di alert terbuka terakhir (selisih baru dikabari; yang sama atau
-- berkurang tidak diulang).
create function finance.reconcile_bank() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  issues jsonb;
begin
  with sys as (
    select i.payment_ref ref, i.paid_amount amt from finance.invoices i where i.status = 'paid' and i.payment_channel in ('transfer', 'qris')
    union all
    select p.bank_ref, -(p.amount - p.fee) from finance.payouts p where p.status = 'paid' and p.channel = 'batch' and p.bank_ref is not null
    union all
    select r.bank_ref, -(r.amount - r.transfer_fee) from finance.org_refunds r where r.status = 'paid' and r.bank_ref is not null
  ), sys_t as (select s.ref, sum(s.amt) amt from sys s group by s.ref),
  bank_t as (select b.reference ref, sum(b.amount) amt from finance.bank_lines b where b.status <> 'manual' group by b.reference)
  update finance.bank_lines b
     set status = case when st.amt = bt.amt then 'matched' else 'open' end
    from bank_t bt left join sys_t st on st.ref = bt.ref
   where b.reference = bt.ref and b.status <> 'manual'
     and b.status <> case when st.amt = bt.amt then 'matched' else 'open' end;

  issues := finance.bank_issues();
  if issues <> '{}' and not coalesce((select a.payload from ops.alerts a where a.kind = 'reconcile.bank' and a.resolved_at is null
                                       order by a.id desc limit 1) @> issues, false) then
    perform ops.raise_alert('reconcile.bank', 'critical', issues);
  end if;
  return issues;
end $$;

create function api.bank_issues() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  return finance.bank_issues();
end $$;

-- Referensi mutasi bank pada transaksi sistem: refund diisi sebelum bukti transfer diunggah (pay_refund mewajibkannya);
-- payout batch / invoice yang referensinya salah ketik dikoreksi dengan catatan. Tercatat di audit, lalu dicocokkan ulang.
create function api.set_bank_ref(p_target text, p_id uuid, p_ref text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  ref text := btrim(coalesce(p_ref, ''));
  old text;
  settled boolean := true;  -- refund approved belum dibayar: referensi boleh diganti tanpa catatan (unggah bukti diulang)
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if ref = '' or length(ref) > 120 then
    raise exception 'invalid:bank_ref' using errcode = 'P0001';
  end if;
  if p_target = 'refund' then
    select r.bank_ref, r.status = 'paid' into old, settled from finance.org_refunds r
     where r.id = p_id and r.status in ('approved', 'paid') for update;
  elsif p_target = 'payout' then
    select p.bank_ref into old from finance.payouts p where p.id = p_id and p.status = 'paid' and p.channel = 'batch' for update;
  elsif p_target = 'invoice' then
    select i.payment_ref into old from finance.invoices i where i.id = p_id and i.status = 'paid' and i.payment_channel in ('transfer', 'qris')
       for update;
  else
    raise exception 'invalid:target' using errcode = 'P0001';
  end if;
  if not found then
    raise exception 'not_found:%', p_target using errcode = 'P0002';
  end if;
  if old is not distinct from ref then
    return finance.reconcile_bank();
  end if;
  if old is not null and settled and length(btrim(coalesce(p_note, ''))) < 3 then  -- koreksi transaksi yang sudah dibayar, wajib alasan
    raise exception 'invalid:note' using errcode = 'P0001';
  end if;
  if p_target = 'refund' then
    update finance.org_refunds set bank_ref = ref where id = p_id;
  elsif p_target = 'payout' then
    update finance.payouts set bank_ref = ref where id = p_id;
  else
    if exists (select 1 from finance.invoices i where i.payment_ref = ref) then
      raise exception 'duplicate_payment_ref' using errcode = '23505';
    end if;
    update finance.invoices set payment_ref = ref where id = p_id;
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'finance.bank_ref', p_target || ':' || p_id, jsonb_build_object('ref', old),
          jsonb_build_object('ref', ref, 'note', nullif(btrim(coalesce(p_note, '')), '')));
  return finance.reconcile_bank();
end $$;

-- p_lines: [{date: 'YYYY-MM-DD', amount: ±nominal, reference, description}] dari CSV (parser app), maks 5.000 baris per unggahan.
-- Baris identik (tanggal, nominal, referensi, keterangan) dibedakan nomor urutnya di dalam file, jadi unggahan wajib memuat
-- mutasi SEHARI PENUH: file untuk tanggal yang sudah ada harus memuat semua baris tersimpan tanggal itu (mutasi bank tidak
-- pernah hilang), selain itu ditolak bank_partial_day — mutasi kembar dari dua potongan file tidak dibuang diam-diam.
create function api.import_bank_lines(p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  n int;
  partial date;
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 5000
     or exists (select 1 from jsonb_array_elements(p_lines) e
                 where coalesce(e ->> 'date', '') !~ '^\d{4}-\d{2}-\d{2}$' or jsonb_typeof(e -> 'amount') is distinct from 'number'
                    or coalesce(btrim(e ->> 'reference'), '') = '' or length(e ->> 'reference') > 120) then
    raise exception 'invalid:bank_lines' using errcode = 'P0001';
  end if;
  with x as (
    select (e ->> 'date')::date d, round((e ->> 'amount')::numeric, 2) a, btrim(e ->> 'reference') r,
           left(coalesce(btrim(e ->> 'description'), ''), 500) ds
      from jsonb_array_elements(p_lines) e
  ), h as (
    select x.*, encode(sha256(convert_to(concat_ws('|', x.d, x.a, x.r, x.ds, row_number() over (partition by x.d, x.a, x.r, x.ds)),
                                         'UTF8')), 'hex') hash
      from x where x.a <> 0
  ), gap as (
    select min(b.value_date) d from finance.bank_lines b
     where b.value_date in (select h.d from h) and not exists (select 1 from h where h.hash = b.line_hash)
  ), ins as (
    insert into finance.bank_lines (value_date, amount, reference, description, line_hash, imported_by)
    select h.d, h.a, h.r, h.ds, h.hash, (select auth.uid()) from h where (select gap.d from gap) is null
    on conflict (line_hash) do nothing
    returning 1
  )
  select (select gap.d from gap), (select count(*) from ins) into partial, n;
  if partial is not null then
    raise exception 'bank_partial_day:%', partial using errcode = 'P0001';
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'finance.bank_import', 'bank_lines', null,
          jsonb_build_object('lines', jsonb_array_length(p_lines), 'inserted', n));
  return jsonb_build_object('inserted', n, 'existing', jsonb_array_length(p_lines) - n, 'issues', finance.reconcile_bank());
end $$;

-- Baris bank yang bukan transaksi sistem (biaya bank, bunga, setoran QRIS gabungan) ditutup dengan catatan; tercatat di audit.
create function api.resolve_bank_line(p_id bigint, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not ops.has_admin('admin_finance') then
    raise exception 'auth:forbidden' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_note, ''))) not between 3 and 500 then
    raise exception 'invalid:note' using errcode = 'P0001';
  end if;
  update finance.bank_lines set status = 'manual', note = btrim(p_note), resolved_by = (select auth.uid()), resolved_at = now()
   where id = p_id and status = 'open';
  if not found then
    raise exception 'invalid_state:bank_line' using errcode = 'P0001';
  end if;
  insert into ops.audit_logs (actor_id, action, target, before, after)
  values ((select auth.uid()), 'finance.bank_resolve', 'bank_line:' || p_id, jsonb_build_object('status', 'open'),
          jsonb_build_object('status', 'manual', 'note', btrim(p_note)));
end $$;

revoke execute on function finance.bank_issues(), finance.reconcile_bank(), api.bank_issues(), api.import_bank_lines(jsonb),
  api.resolve_bank_line(bigint, text), api.set_bank_ref(text, uuid, text, text) from public;
grant execute on function api.bank_issues(), api.import_bank_lines(jsonb), api.resolve_bank_line(bigint, text),
  api.set_bank_ref(text, uuid, text, text) to authenticated;
