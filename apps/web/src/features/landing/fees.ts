// Contoh hitung brand (§5.2): fee dihitung di atas budget creator; clipper menerima 100% budget creator.
// Default 15% + 5% (E-21) = cadangan kalau fee rule global (api.fee_rules, terbaca anon) gagal dibaca.
export const MGMT_FEE_PCT = 15;
export const ADMIN_FEE_PCT = 5;

export function brandCost(budget: number, mgmtPct = MGMT_FEE_PCT, adminPct = ADMIN_FEE_PCT) {
  const mgmt = Math.round((budget * mgmtPct) / 100);
  const admin = Math.round((budget * adminPct) / 100);
  return { budget, mgmt, admin, total: budget + mgmt + admin };
}
