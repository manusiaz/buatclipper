/** Trust Score = 50 + Σ delta E-40, dibatasi 0–100 (rumus job:trust-score, trust.recalc_scores). api.profiles tidak mengekspos trust_score. */
export const trustScore = (deltas: number[]) => Math.max(0, Math.min(100, 50 + deltas.reduce((a, b) => a + b, 0)));
