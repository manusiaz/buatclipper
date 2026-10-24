import type { ReactNode } from 'react';
import { requireAdmin } from '@clipper/auth/server';
import { AdminShell } from '@/features/shell/admin-shell';

export default async function ConsoleLayout({ children }: { children: ReactNode }) {
  const { claims } = await requireAdmin();
  return (
    <AdminShell email={claims.email ?? ''} roles={claims.app_roles}>
      {children}
    </AdminShell>
  );
}
