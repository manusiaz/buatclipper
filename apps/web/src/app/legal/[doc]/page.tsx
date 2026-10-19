import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { getTranslations } from 'next-intl/server';
import { Container } from '@clipper/ui';
import { Markdown } from '@/components/markdown';
import { LEGAL_DOCS, isLegalDoc, readLegalDoc } from '@/features/legal/docs';

type Props = { params: Promise<{ doc: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { doc } = await params;
  if (!isLegalDoc(doc)) return {};
  const t = await getTranslations('web.legal');
  return { title: t(`titles.${doc}`), alternates: { canonical: `/legal/${doc}` } };
}

/** §16 ToS clipper, ToS brand, privasi: Markdown dari tim legal (content/legal/<doc>.md). */
export default async function LegalPage({ params }: Props) {
  const { doc } = await params;
  if (!isLegalDoc(doc)) notFound();
  const [t, body] = await Promise.all([getTranslations('web.legal'), readLegalDoc(doc)]);
  return (
    <Container size="sm" className="py-10 md:py-16">
      <nav aria-label={t('others')} className="mb-8 flex flex-wrap gap-2">
        {LEGAL_DOCS.map((d) => (
          <Link
            key={d}
            href={`/legal/${d}`}
            aria-current={d === doc ? 'page' : undefined}
            className="inline-flex min-h-11 items-center rounded-full border border-border px-4 text-body-s font-semibold text-text-2 hover:bg-subtle focus-ring aria-[current=page]:border-transparent aria-[current=page]:bg-primary-soft aria-[current=page]:text-primary-soft-fg"
          >
            {t(`titles.${d}`)}
          </Link>
        ))}
      </nav>
      <article className="surface-card rounded-card p-6 md:p-10">
        <Markdown>{body}</Markdown>
      </article>
    </Container>
  );
}
