import Markdown from 'react-markdown';

// Brief brand = Markdown tanpa HTML mentah (skipHtml, tanpa rehype-raw — R-16); link keluar tab baru.
export function Brief({ source }: { source: string }) {
  return (
    <div className="flex flex-col gap-3 text-body-s text-text-2 [&_strong]:text-ink">
      <Markdown
        skipHtml
        components={{
          h1: ({ children }) => <h3 className="text-h6 text-ink">{children}</h3>,
          h2: ({ children }) => <h3 className="text-h6 text-ink">{children}</h3>,
          h3: ({ children }) => <h4 className="text-label text-ink">{children}</h4>,
          p: ({ children }) => <p className="leading-relaxed">{children}</p>,
          ul: ({ children }) => <ul className="ml-5 list-disc space-y-1">{children}</ul>,
          ol: ({ children }) => <ol className="ml-5 list-decimal space-y-1">{children}</ol>,
          a: ({ href, children }) => (
            <a href={href} target="_blank" rel="noopener noreferrer nofollow" className="font-semibold text-link underline-offset-2 hover:underline">
              {children}
            </a>
          ),
          img: ({ src, alt }) =>
            typeof src === 'string' && src.startsWith('https://') ? (
              <img src={src} alt={alt ?? ''} loading="lazy" className="max-h-80 rounded-card-sm object-contain" />
            ) : null,
          code: ({ children }) => <code className="rounded-tag bg-subtle px-1 py-0.5 text-[0.9em]">{children}</code>,
          blockquote: ({ children }) => <blockquote className="border-l-4 border-border-strong pl-3 italic">{children}</blockquote>,
        }}
      >
        {source}
      </Markdown>
    </div>
  );
}
