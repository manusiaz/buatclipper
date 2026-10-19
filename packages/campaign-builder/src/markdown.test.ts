import { isValidElement, type ReactNode } from 'react';
import { describe, expect, it } from 'vitest';
import { renderMarkdown } from './markdown';

interface Node {
  type: string;
  props: Record<string, unknown>;
  children: (Node | string)[];
}

function tree(node: ReactNode): (Node | string)[] {
  if (node == null || typeof node === 'boolean') return [];
  if (typeof node === 'string' || typeof node === 'number') return [String(node)];
  if (Array.isArray(node)) return node.flatMap(tree);
  if (isValidElement<{ children?: ReactNode }>(node)) {
    const { children, ...props } = node.props;
    return [{ type: String(node.type), props, children: tree(children) }];
  }
  return [];
}

const all = (nodes: (Node | string)[]): Node[] => nodes.flatMap((n) => (typeof n === 'string' ? [] : [n, ...all(n.children)]));
const text = (nodes: (Node | string)[]): string => nodes.map((n) => (typeof n === 'string' ? n : text(n.children))).join('');
const render = (src: string) => tree(renderMarkdown(src));

describe('SafeMarkdown (R-16: no raw HTML)', () => {
  it('keeps raw HTML as visible text and never uses dangerouslySetInnerHTML', () => {
    const nodes = render('<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>');
    expect(all(nodes).every((n) => !('dangerouslySetInnerHTML' in n.props))).toBe(true);
    expect(all(nodes).map((n) => n.type)).toEqual(['p', 'p']);
    expect(text(nodes)).toContain('<script>alert(1)</script>');
    expect(text(nodes)).toContain('<img src=x onerror=alert(1)>');
  });

  it('only https links become anchors (nofollow noopener, new tab); images reduce to alt text', () => {
    const nodes = render('[aman](https://studio.id) [jahat](javascript:alert(1)) [http](http://x.id) ![logo](https://x/y.png) https://auto.link/x.');
    const anchors = all(nodes).filter((n) => n.type === 'a');
    expect(anchors.map((a) => a.props.href)).toEqual(['https://studio.id', 'https://auto.link/x']);
    expect(anchors.every((a) => a.props.rel === 'nofollow noopener noreferrer' && a.props.target === '_blank')).toBe(true);
    expect(all(nodes).some((n) => n.type === 'img')).toBe(false);
    expect(text(nodes)).toContain('jahat');
    expect(text(nodes)).toContain('logo');
  });

  it('renders headings, emphasis, code, lists, quotes and line breaks', () => {
    const nodes = render('# Judul\nBaris **tebal** dan *miring* dan `kode`\nbaris dua\n\n- satu\n- dua\n\n1. a\n2. b\n\n> kutipan\n\n```\n<b>x</b>\n```\n\n---');
    expect(all(nodes).map((n) => n.type)).toEqual(
      expect.arrayContaining(['h3', 'p', 'strong', 'em', 'code', 'br', 'ul', 'li', 'ol', 'blockquote', 'pre', 'hr']),
    );
    const pre = all(nodes).find((n) => n.type === 'pre')!;
    expect(text([pre])).toBe('<b>x</b>');
  });

  it('empty source renders nothing', () => {
    expect(renderMarkdown('  \n\n ')).toEqual([]);
  });
});
