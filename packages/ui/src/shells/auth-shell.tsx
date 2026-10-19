import type { ReactNode } from 'react';
import { cn } from '../lib/cn';
import { Logo } from '../components/logo';

export interface AuthShellProps {
  children: ReactNode;
  title?: ReactNode;
  description?: ReactNode;
  /** Above the card. Default <Logo/>. */
  logo?: ReactNode;
  /** Under the card: "Belum punya akun? Daftar", legal links. */
  footer?: ReactNode;
  /** Optional side panel on ≥ 1024 px (e.g. DARK surface with benefits / photo). */
  aside?: ReactNode;
  /** Card width: sm 400 · md 440 (default) · lg 560 (onboarding forms). */
  size?: 'sm' | 'md' | 'lg';
  /** Top-right slot (language / theme toggle). */
  topRight?: ReactNode;
  className?: string;
}

const W = { sm: 'max-w-[400px]', md: 'max-w-[440px]', lg: 'max-w-[560px]' } as const;

/** Login / onboarding: PAGE gradient, logo, centered CARD (DS ds-notes PAGE + CARD). Server-compatible. */
export function AuthShell({ children, title, description, logo, footer, aside, size = 'md', topRight, className }: AuthShellProps) {
  return (
    <div className={cn('bg-page relative flex min-h-dvh', className)}>
      {aside ? <aside className="surface-dark hidden w-[44%] max-w-[640px] shrink-0 rounded-none shadow-none lg:flex lg:flex-col">{aside}</aside> : null}
      <div className="flex min-h-dvh min-w-0 flex-1 flex-col px-4 pt-[calc(var(--safe-top)+24px)] pb-[calc(var(--safe-bottom)+24px)]">
        {topRight ? <div className="absolute top-[calc(var(--safe-top)+12px)] right-4 flex items-center gap-1">{topRight}</div> : null}
        <div className={cn('m-auto flex w-full min-w-0 flex-col items-center gap-6', W[size])}>
          <div className="flex justify-center">{logo ?? <Logo size={36} />}</div>
          <main id="main" className="surface-card w-full min-w-0 rounded-card p-5 sm:p-8">
            {title || description ? (
              <div className="mb-6 flex flex-col gap-1.5 text-center">
                {title ? <h1 className="text-h4 text-ink">{title}</h1> : null}
                {description ? <p className="text-body-s text-muted">{description}</p> : null}
              </div>
            ) : null}
            {children}
          </main>
          {footer ? <div className="text-center text-body-s text-muted">{footer}</div> : null}
        </div>
      </div>
    </div>
  );
}
