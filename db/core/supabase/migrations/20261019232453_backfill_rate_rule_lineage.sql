-- raise_rate sebelum lineage_id ada: versi berikutnya = rule di pool/kind/platform yang sama yang mulai tepat saat versi
-- sebelumnya ditutup (raise_rate memakai satu waktu t untuk keduanya). Rantai ditelusuri dari rule pertama, termasuk versi
-- yang sudah ber-lineage_id (dibuat sesudah kolom ada di atas versi lama), lalu semuanya diseragamkan ke rule pertama.
-- Rule independen tidak tersambung.
with recursive chain (id, root) as (
  select r.id, r.id from market.rate_rules r
   where not exists (select 1 from market.rate_rules o
                      where o.campaign_id = r.campaign_id and o.pool_id = r.pool_id and o.kind = r.kind
                        and o.platform is not distinct from r.platform and o.effective_to = r.effective_from)
  union all
  select n.id, c.root from chain c
    join market.rate_rules o on o.id = c.id
    join market.rate_rules n on n.campaign_id = o.campaign_id and n.pool_id = o.pool_id and n.kind = o.kind
                            and n.platform is not distinct from o.platform and n.effective_from = o.effective_to
)
update market.rate_rules r set lineage_id = c.root
  from chain c
 where r.id = c.id and c.id <> c.root and r.lineage_id is distinct from c.root;
