import type { Metadata } from 'next';
import { notFound } from 'next/navigation';
import { getTranslations } from 'next-intl/server';
import { getReport } from '@/features/report/data';
import { ReportView } from '@/features/report/report-view';

type Props = { params: Promise<{ token: string }> };

// Token = kredensial baca: jangan diindeks, jangan dikirim sebagai referrer ke embed/tautan luar.
export async function generateMetadata(): Promise<Metadata> {
  const t = await getTranslations('web.report');
  return { title: t('metaTitle'), robots: { index: false, follow: false }, referrer: 'no-referrer' };
}

/** B3.6 → {domain}/r/[token]: laporan read-only tanpa login; dicabut/kedaluwarsa → "Link tidak berlaku" (404). */
export default async function ReportPage({ params }: Props) {
  const { token } = await params;
  const report = await getReport(token);
  if (!report) notFound();
  return <ReportView report={report} />;
}
