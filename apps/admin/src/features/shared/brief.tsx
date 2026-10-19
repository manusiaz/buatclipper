import Markdown from 'react-markdown';
import { cn } from '@clipper/ui';

/** Brief Markdown (tanpa HTML mentah — default react-markdown, R-16). */
export function Brief({ text, className }: { text: string | null | undefined; className?: string }) {
  if (!text?.trim()) return <p className="text-body-s text-muted">—</p>;
  return (
    <div
      className={cn(
        'text-body-s leading-relaxed text-text-2 break-words',
        '[&_h1]:mt-3 [&_h1]:text-h6 [&_h1]:text-ink [&_h2]:mt-3 [&_h2]:text-h6 [&_h2]:text-ink [&_h3]:mt-2 [&_h3]:font-semibold [&_h3]:text-ink',
        '[&_p]:my-1.5 [&_ul]:my-1.5 [&_ul]:list-disc [&_ul]:pl-5 [&_ol]:my-1.5 [&_ol]:list-decimal [&_ol]:pl-5 [&_a]:text-link [&_a]:underline',
        '[&_code]:rounded-tag [&_code]:bg-subtle [&_code]:px-1 [&_blockquote]:border-l-2 [&_blockquote]:border-border [&_blockquote]:pl-3',
        className,
      )}
    >
      <Markdown components={{ a: ({ href, children }) => <a href={href} target="_blank" rel="noopener noreferrer">{children}</a> }}>{text}</Markdown>
    </div>
  );
}
