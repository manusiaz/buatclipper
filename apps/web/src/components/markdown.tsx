import type { ComponentProps, ReactNode } from 'react';
import ReactMarkdown, { type Components } from 'react-markdown';
import { cn } from '@clipper/ui';

type Level = 1 | 2 | 3 | 4 | 5 | 6;
const HEADING: Record<Level, string> = {
  1: 'text-h2 mt-2 mb-4',
  2: 'text-h4 mt-8 mb-3',
  3: 'text-h5 mt-6 mb-2',
  4: 'text-h6 mt-5 mb-2',
  5: 'text-h6 mt-4 mb-1',
  6: 'text-label mt-4 mb-1',
};

function heading(n: number, offset: number) {
  const level = Math.min(6, n + offset) as Level;
  const Tag = `h${level}` as const;
  return function H({ children }: { children?: ReactNode }) {
    return <Tag className={cn('text-ink', HEADING[level])}>{children}</Tag>;
  };
}

function A({ href, children }: ComponentProps<'a'>) {
  if (!href) return <>{children}</>;
  const internal = href.startsWith('/') || href.startsWith('#');
  return (
    <a
      href={href}
      className="rounded-tag font-semibold text-link underline underline-offset-2 focus-ring"
      {...(internal ? {} : { target: '_blank', rel: 'noopener noreferrer nofollow' })}
    >
      {children}
    </a>
  );
}

/**
 * Markdown aman (R-16): react-markdown tanpa rehype-raw, HTML mentah dibuang (skipHtml), URL disaring urlTransform
 * bawaan, gambar luar tidak dimuat (cuma alt) supaya brief tidak bisa memasang pixel pelacak di {domain}.
 */
export function Markdown({ children, headingOffset = 0, className }: { children: string; headingOffset?: number; className?: string }) {
  const components: Components = {
    h1: heading(1, headingOffset),
    h2: heading(2, headingOffset),
    h3: heading(3, headingOffset),
    h4: heading(4, headingOffset),
    h5: heading(5, headingOffset),
    h6: heading(6, headingOffset),
    p: ({ children: c }) => <p className="my-3">{c}</p>,
    ul: ({ children: c }) => <ul className="my-3 list-disc space-y-1.5 pl-5 marker:text-faint">{c}</ul>,
    ol: ({ children: c }) => <ol className="my-3 list-decimal space-y-1.5 pl-5 marker:text-muted">{c}</ol>,
    blockquote: ({ children: c }) => <blockquote className="my-4 border-l-4 border-primary-soft pl-4 text-text-2">{c}</blockquote>,
    code: ({ children: c }) => <code className="rounded-tag bg-subtle px-1 py-0.5 font-mono text-[0.9em]">{c}</code>,
    pre: ({ children: c }) => <pre className="my-4 overflow-x-auto rounded-card-sm bg-subtle p-4 text-body-s [&_code]:bg-transparent [&_code]:p-0">{c}</pre>,
    hr: () => <hr className="my-6 border-border" />,
    strong: ({ children: c }) => <strong className="font-bold text-ink">{c}</strong>,
    a: A,
    img: ({ alt }) => (alt ? <span className="text-muted">[{alt}]</span> : null),
  };
  return (
    <div className={cn('text-body break-words text-text-2', className)}>
      <ReactMarkdown skipHtml components={components}>
        {children}
      </ReactMarkdown>
    </div>
  );
}
