-- DIBANGKITKAN scripts/gen-bus-accept.mjs dari trigger bus.replicate pengirim — jangan diedit tangan.
-- Kolom yang boleh ditulis tiap pengirim lewat rep.row di DB ini (bus.apply_row); selain itu ditolak.
create function bus.accepts(p_source text, p_table text) returns text[]
language sql immutable set search_path = '' as $$
  select v.cols from (values
    ('admin', 'market.campaigns', array['status', 'start_at', 'submit_deadline', 'view_window_days', 'pinned_until']),
    ('admin', 'market.categories', array['name_id', 'name_en', 'sort', 'active']),
    ('admin', 'market.profiles', array['status', 'suspended_until', 'trust_score']),
    ('creator', 'market.profiles', array['username', 'display_name', 'avatar_path'])
  ) v(source, tbl, cols) where v.source = p_source and v.tbl = p_table;
$$;
revoke execute on function bus.accepts(text, text) from public;
