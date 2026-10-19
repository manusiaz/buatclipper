/** Alasan standar penolakan klip (reason_code E-19); teks di brand.review.reasons.<kode>. */
export const REJECT_REASONS = ['off_brief', 'missing_tags', 'low_quality', 'inappropriate', 'misleading', 'duplicate', 'other'] as const;
export type RejectReason = (typeof REJECT_REASONS)[number];
