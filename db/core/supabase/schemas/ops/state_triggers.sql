-- DIBANGKITKAN spec/gen_states.py dari spec/kg.yaml (states). Jangan edit manual: ubah YAML lalu jalankan ulang.

-- S-01 campaign
create trigger campaigns_state_machine before insert or update of status on market.campaigns
  for each row execute function ops.check_transition('S-01', 'draft', '{"draft":["in_review","cancelled"],"in_review":["scheduled","rejected","cancelled"],"rejected":["draft"],"scheduled":["live","cancelled"],"live":["paused","tracking","exhausted"],"paused":["live","tracking","exhausted"],"tracking":["settling","exhausted"],"exhausted":["settling"],"settling":["settled"]}');

-- S-02 claim
create trigger claims_state_machine before insert or update of status on market.claims
  for each row execute function ops.check_transition('S-02', 'open', '{"open":["submitted","expired","released"]}');

-- S-03 submission
create trigger submissions_state_machine before insert or update of status on tracking.submissions
  for each row execute function ops.check_transition('S-03', 'validating', '{"validating":["in_review","tracking","rejected"],"in_review":["tracking","rejected"],"rejected":["appealed"],"appealed":["tracking","rejected_final"],"tracking":["flagged","forfeited","locked"],"flagged":["tracking","forfeited"],"locked":["settled"]}');

-- S-05 payout
create trigger payouts_state_machine before insert or update of status on finance.payouts
  for each row execute function ops.check_transition('S-05', 'requested', '{"requested":["on_hold","processing"],"on_hold":["processing","cancelled"],"processing":["paid","failed"],"failed":["requested","returned"]}');

-- S-06 fulfillment
create trigger fulfillments_state_machine before insert or update of status on finance.fulfillments
  for each row execute function ops.check_transition('S-06', 'requested', '{"requested":["on_hold","processing"],"on_hold":["processing","cancelled"],"processing":["delivered","failed"],"failed":["requested","returned"]}');
