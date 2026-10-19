'use client';

import { createContext, useContext, type ElementType, type ReactNode } from 'react';

const LinkContext = createContext<ElementType>('a');

/**
 * Optional: set the router link component once (e.g. next/link) for client shells/components that render links.
 * Use inside a client providers file: <LinkProvider component={Link}>…</LinkProvider>.
 * Server-compatible components take `linkAs` instead.
 */
export function LinkProvider({ component, children }: { component: ElementType; children: ReactNode }) {
  return <LinkContext.Provider value={component}>{children}</LinkContext.Provider>;
}

export function useLinkComponent(override?: ElementType): ElementType {
  const ctx = useContext(LinkContext);
  return override ?? ctx;
}
