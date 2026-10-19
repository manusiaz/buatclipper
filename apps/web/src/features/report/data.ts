import { core, deadline } from '@/lib/core';
import { isReportToken, parseReport, type Report } from './parse';

/** F-B09: api.report_by_token (anon). Tidak di-cache: link yang dicabut harus langsung tidak berlaku. */
export async function getReport(token: string): Promise<Report | null> {
  if (!isReportToken(token)) return null;
  const { data, error } = await core.rpc('report_by_token', { p_token: token }).abortSignal(deadline(8000));
  if (error) throw new Error(error.message);
  return parseReport(data);
}
