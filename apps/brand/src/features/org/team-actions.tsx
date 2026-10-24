'use client';

import { useTransition } from 'react';
import { useTranslations } from 'next-intl';
import { ConfirmDialog, IconButton, Select, toast } from '@clipper/ui';
import type { OrgRole } from '@/lib/org';
import { useErrorText } from '@/lib/use-error';
import { manageTeam } from './actions';

const ROLES: OrgRole[] = ['brand_owner', 'brand_manager', 'brand_finance', 'brand_viewer'];

function useTeamAction() {
  const t = useTranslations('brand');
  const errText = useErrorText();
  const [pending, start] = useTransition();
  const run = (orgId: string, action: 'set_role' | 'remove' | 'revoke_invite', target: string, role?: OrgRole) =>
    new Promise<void>((resolve) =>
      start(async () => {
        const res = await manageTeam(orgId, action, target, role);
        resolve();
        if (!res.ok) return void toast.error(errText(res.error));
        toast.success(t(`team.updated.${action}`));
      }),
    );
  return { t, pending, run };
}

/** Ubah role + keluarkan anggota (B2, brand_owner langsung). */
export function MemberActions({ orgId, userId, role, name }: { orgId: string; userId: string; role: OrgRole; name: string }) {
  const { t, pending, run } = useTeamAction();
  return (
    <span className="flex items-center gap-2">
      <Select
        inputSize="sm"
        aria-label={t('team.roleFor', { name })}
        value={role}
        disabled={pending}
        onValueChange={(v) => v !== role && run(orgId, 'set_role', userId, v as OrgRole)}
        options={ROLES.map((r) => ({ value: r, label: t(`roles.${r}`) }))}
        className="min-w-[150px]"
      />
      <ConfirmDialog
        trigger={<IconButton icon="delete" label={t('team.remove', { name })} variant="ghost" size="sm" />}
        title={t('team.removeTitle', { name })}
        description={t('team.removeBody')}
        confirmLabel={t('team.removeConfirm')}
        cancelLabel={t('team.cancel')}
        onConfirm={() => run(orgId, 'remove', userId)}
      />
    </span>
  );
}

/** Cabut link undangan yang belum dipakai. */
export function RevokeInvite({ orgId, inviteId }: { orgId: string; inviteId: string }) {
  const { t, run } = useTeamAction();
  return (
    <ConfirmDialog
      trigger={<IconButton icon="link_off" label={t('team.revoke')} variant="ghost" size="sm" />}
      title={t('team.revokeTitle')}
      description={t('team.revokeBody')}
      confirmLabel={t('team.revoke')}
      cancelLabel={t('team.cancel')}
      onConfirm={() => run(orgId, 'revoke_invite', inviteId)}
    />
  );
}
