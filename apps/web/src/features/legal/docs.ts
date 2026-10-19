import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

// §16: teks legal disediakan tim legal sebagai Markdown di apps/web/content/legal/<doc>.md (ikut di-trace ke output build
// lewat outputFileTracingIncludes). Versi & tanggal resmi ada di identity (member.legal_versions), bukan di sini.
export const LEGAL_DOCS = ['tos-clipper', 'tos-brand', 'privacy'] as const;
export type LegalDoc = (typeof LEGAL_DOCS)[number];

export const isLegalDoc = (v: string): v is LegalDoc => (LEGAL_DOCS as readonly string[]).includes(v);

export const readLegalDoc = (doc: LegalDoc) => readFile(join(process.cwd(), 'content', 'legal', `${doc}.md`), 'utf8');
