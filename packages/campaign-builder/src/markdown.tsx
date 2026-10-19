import type { ReactNode } from 'react';

/*
 * Tiny safe Markdown renderer for the campaign brief (PRD §15.6 / R-16: brief is rendered as Markdown WITHOUT raw HTML,
 * because app.{domain} shares the session cookie). Output is React elements only — text is always escaped by React,
 * raw HTML in the source stays visible text, images are reduced to their alt text, and only https:// links become
 * anchors (rel="nofollow noopener noreferrer", new tab). Supports: headings, paragraphs, line breaks, bold, italic,
 * inline code, fenced code, bullet/numbered lists, blockquotes, horizontal rules, links.
 */

const SAFE_HREF = /^https:\/\/[^\s]+$/;

const INLINE =
  /(`+)([\s\S]*?[^`])\1(?!`)|\*\*([\s\S]+?)\*\*|__([\s\S]+?)__|\*(?!\s)([^*]+?)\*|(?<![\p{L}\p{N}])_(?!\s)([^_]+?)_(?![\p{L}\p{N}])|!\[([^\]]*)\]\(([^)\s]*)\)|\[([^\]]+)\]\(([^)\s]+)\)|(https:\/\/[^\s<>]*[^\s<>.,:;"')\]!?])|\\([\\`*_{}[\]()#+\-.!>|~])/gu;

function inline(text: string, keyBase: string): ReactNode[] {
  const out: ReactNode[] = [];
  let last = 0;
  let i = 0;
  INLINE.lastIndex = 0;
  const re = new RegExp(INLINE.source, INLINE.flags);
  for (let m = re.exec(text); m; m = re.exec(text)) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const key = `${keyBase}.${i++}`;
    if (m[2] !== undefined) out.push(<code key={key} className="rounded-tag bg-subtle px-1 py-0.5 font-mono text-[0.9em]">{m[2]}</code>);
    else if (m[3] !== undefined || m[4] !== undefined) out.push(<strong key={key}>{inline(m[3] ?? m[4] ?? '', key)}</strong>);
    else if (m[5] !== undefined || m[6] !== undefined) out.push(<em key={key}>{inline(m[5] ?? m[6] ?? '', key)}</em>);
    else if (m[7] !== undefined) out.push(m[7]);
    else if (m[9] !== undefined) {
      const href = m[10] ?? '';
      out.push(
        SAFE_HREF.test(href) ? (
          <a key={key} href={href} target="_blank" rel="nofollow noopener noreferrer" className="font-semibold text-link underline underline-offset-2">
            {inline(m[9], key)}
          </a>
        ) : (
          <span key={key}>{inline(m[9], key)}</span>
        ),
      );
    } else if (m[11] !== undefined) {
      out.push(
        <a key={key} href={m[11]} target="_blank" rel="nofollow noopener noreferrer" className="break-all font-semibold text-link underline underline-offset-2">
          {m[11]}
        </a>,
      );
    } else if (m[12] !== undefined) out.push(m[12]);
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

function withBreaks(lines: string[], keyBase: string): ReactNode[] {
  const out: ReactNode[] = [];
  lines.forEach((line, i) => {
    if (i > 0) out.push(<br key={`${keyBase}.br${i}`} />);
    out.push(...inline(line, `${keyBase}.${i}`));
  });
  return out;
}

const HEADING = /^(#{1,6})\s+(.*?)\s*#*\s*$/;
const BULLET = /^\s{0,3}[-*+]\s+(.*)$/;
const ORDERED = /^\s{0,3}\d{1,9}[.)]\s+(.*)$/;
const QUOTE = /^\s{0,3}>\s?(.*)$/;
const FENCE = /^\s{0,3}(```|~~~)/;
const RULE = /^\s{0,3}([-*_])(\s*\1){2,}\s*$/;

export function renderMarkdown(source: string): ReactNode[] {
  const lines = source.replace(/\r\n?/g, '\n').split('\n');
  const blocks: ReactNode[] = [];
  let i = 0;
  let k = 0;
  const key = () => `b${k++}`;
  while (i < lines.length) {
    const line = lines[i]!;
    if (line.trim() === '') {
      i++;
      continue;
    }
    const fence = FENCE.exec(line);
    if (fence) {
      const body: string[] = [];
      i++;
      while (i < lines.length && !lines[i]!.trim().startsWith(fence[1]!)) body.push(lines[i++]!);
      i++;
      blocks.push(
        <pre key={key()} className="overflow-x-auto rounded-chip bg-subtle p-3 font-mono text-body-s">
          <code>{body.join('\n')}</code>
        </pre>,
      );
      continue;
    }
    if (RULE.test(line)) {
      blocks.push(<hr key={key()} className="border-border" />);
      i++;
      continue;
    }
    const h = HEADING.exec(line);
    if (h) {
      const level = h[1]!.length;
      const k2 = key();
      const content = inline(h[2] ?? '', k2);
      blocks.push(
        level <= 1 ? (
          <h3 key={k2} className="text-h5">{content}</h3>
        ) : level === 2 ? (
          <h4 key={k2} className="text-h6">{content}</h4>
        ) : (
          <h5 key={k2} className="text-label font-bold">{content}</h5>
        ),
      );
      i++;
      continue;
    }
    if (BULLET.test(line) || ORDERED.test(line)) {
      const ordered = !BULLET.test(line);
      const re = ordered ? ORDERED : BULLET;
      const items: string[][] = [];
      while (i < lines.length) {
        const cur = lines[i]!;
        const m = re.exec(cur);
        if (m) items.push([m[1] ?? '']);
        else if (cur.trim() !== '' && /^\s{2,}\S/.test(cur) && items.length) items[items.length - 1]!.push(cur.trim());
        else break;
        i++;
      }
      const k2 = key();
      const children = items.map((it, j) => <li key={`${k2}.${j}`}>{withBreaks(it, `${k2}.${j}`)}</li>);
      blocks.push(
        ordered ? (
          <ol key={k2} className="list-decimal space-y-1 pl-5">{children}</ol>
        ) : (
          <ul key={k2} className="list-disc space-y-1 pl-5">{children}</ul>
        ),
      );
      continue;
    }
    if (QUOTE.test(line)) {
      const body: string[] = [];
      while (i < lines.length && QUOTE.test(lines[i]!)) body.push(QUOTE.exec(lines[i++]!)![1] ?? '');
      const k2 = key();
      blocks.push(
        <blockquote key={k2} className="border-l-4 border-border-strong pl-3 text-text-2">
          {withBreaks(body, k2)}
        </blockquote>,
      );
      continue;
    }
    const para: string[] = [];
    while (
      i < lines.length &&
      lines[i]!.trim() !== '' &&
      !(para.length > 0 && (HEADING.test(lines[i]!) || FENCE.test(lines[i]!) || BULLET.test(lines[i]!) || QUOTE.test(lines[i]!)))
    ) {
      para.push(lines[i++]!);
    }
    const k2 = key();
    blocks.push(<p key={k2}>{withBreaks(para, k2)}</p>);
  }
  return blocks;
}

export interface SafeMarkdownProps {
  source: string;
  className?: string;
  /** Rendered when the source is empty. */
  empty?: ReactNode;
}

/** Brief preview / clipper-facing brief. Server-compatible (no hooks). */
export function SafeMarkdown({ source, className, empty = null }: SafeMarkdownProps) {
  const blocks = renderMarkdown(source ?? '');
  return (
    <div className={['flex flex-col gap-3 text-body break-words text-ink', className].filter(Boolean).join(' ')}>
      {blocks.length ? blocks : empty}
    </div>
  );
}
