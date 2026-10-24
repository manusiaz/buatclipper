"""Bangkitkan enum status + trigger state machine core dari spec/kg.yaml (states S-01..S-06), supaya transisi yang
diizinkan di database = transisi di PRD §14. S-04 (earning) hidup di ledger sebagai bucket append-only, jadi tidak dibangkitkan."""
import json, os, yaml

S = os.path.join(os.path.dirname(os.path.realpath(__file__)), '..')  # root repo
KG = yaml.safe_load(open(f'{S}/spec/kg.yaml', encoding='utf-8'))
MAP = {  # state machine → (enum, tabel, status awal)
    'S-01 campaign': ('market.campaign_status', 'market.campaigns', 'draft'),
    'S-02 claim': ('market.claim_status', 'market.claims', 'open'),
    'S-03 submission': ('tracking.submission_status', 'tracking.submissions', 'validating'),
    'S-05 payout': ('finance.payout_status', 'finance.payouts', 'requested'),
    'S-06 fulfillment': ('finance.fulfillment_status', 'finance.fulfillments', 'requested'),
}
HEAD = '-- DIBANGKITKAN spec/gen_states.py dari spec/kg.yaml (states). Jangan edit manual: ubah YAML lalu jalankan ulang.\n'
types, trig = [HEAD], [HEAD]
for name, (enum, table, initial) in MAP.items():
    graph = KG['states'][name]
    order, seen = [], set()
    queue = [initial]
    while queue:  # urutan nilai enum = BFS dari status awal, lalu sisanya
        s = queue.pop(0)
        if s in seen:
            continue
        seen.add(s); order.append(s)
        queue += graph.get(s, [])
    order += sorted(({t for ts in graph.values() for t in ts} | set(graph)) - seen)
    vals = ', '.join(f"'{v}'" for v in order)
    types.append(f"-- {name}\ncreate type {enum} as enum ({vals});\n")
    allowed = json.dumps({k: v for k, v in graph.items()}, separators=(',', ':'))
    tname = table.split('.')[1]
    trig.append(f"-- {name}\ncreate trigger {tname}_state_machine before insert or update of status on {table}\n"
                f"  for each row execute function ops.check_transition('{name.split()[0]}', '{initial}', '{allowed}');\n")
types.append('''-- Satu fungsi untuk semua state machine: insert wajib mulai dari status awal, update hanya lewat transisi yang diizinkan.
create function ops.check_transition() returns trigger
language plpgsql set search_path = '' as $$
declare
  machine text := tg_argv[0];
  initial text := tg_argv[1];
  allowed jsonb := tg_argv[2]::jsonb;
begin
  if tg_op = 'INSERT' then
    if new.status::text <> initial then
      raise exception '% (%): status awal harus %', tg_table_name, machine, initial using errcode = '23514';
    end if;
  elsif new.status is distinct from old.status then
    if not coalesce((allowed -> (old.status::text)) ? (new.status::text), false) then
      raise exception '% (%): transisi % → % tidak diizinkan', tg_table_name, machine, old.status, new.status
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
''')
out = f'{S}/db/core/supabase/schemas/ops'
open(f'{out}/states.sql', 'w', encoding='utf-8').write('\n'.join(types))
open(f'{out}/state_triggers.sql', 'w', encoding='utf-8').write('\n'.join(trig))
print('states.sql + state_triggers.sql:', len(MAP), 'state machine')
