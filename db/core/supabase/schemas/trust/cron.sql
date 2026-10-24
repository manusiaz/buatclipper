-- job:trust-score (19:00 UTC = 02:00 WIB): hitung ulang Trust Score dari E-40 (trust.recalc_scores, kontrak di Lampiran A).
select cron.schedule('trust-score', '0 19 * * *', $$select trust.recalc_scores()$$);
