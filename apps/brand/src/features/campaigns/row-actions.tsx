'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useTransition } from 'react';
import { useTranslations } from 'next-intl';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLinkItem,
  DropdownMenuTrigger,
  IconButton,
  toast,
} from '@clipper/ui';
import { useErrorText } from '@/lib/use-error';
import { duplicateCampaign } from './actions';

/** Menu baris campaign/template: buka, edit, duplikat, simpan sebagai template, pakai template. */
export function CampaignRowActions({
  orgId,
  id,
  title,
  isTemplate,
  editable,
  canEdit,
}: {
  orgId: string;
  id: string;
  title: string;
  isTemplate: boolean;
  editable: boolean;
  canEdit: boolean;
}) {
  const t = useTranslations('brand.campaigns');
  const errText = useErrorText();
  const router = useRouter();
  const [pending, start] = useTransition();
  const builder = (cid: string) => `/${orgId}/campaigns/new?campaign=${cid}`;

  const duplicate = (asTemplate: boolean) =>
    start(async () => {
      const res = await duplicateCampaign(orgId, id, asTemplate);
      if (!res.ok) {
        toast.error(errText(res.error));
        return;
      }
      if (asTemplate) {
        toast.success(t('savedAsTemplate'));
        router.push(`/${orgId}/campaigns?tab=templates`);
      } else {
        toast.success(t('duplicated'));
        router.push(builder(res.id));
      }
    });

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <IconButton icon="more_vert" label={t('actionsFor', { title })} size="sm" loading={pending} />
      </DropdownMenuTrigger>
      <DropdownMenuContent>
        {!isTemplate ? (
          <DropdownMenuLinkItem href={`/${orgId}/campaigns/${id}`} linkAs={Link} icon="monitoring">
            {t('openDashboard')}
          </DropdownMenuLinkItem>
        ) : null}
        {canEdit ? (
          <>
            <DropdownMenuLinkItem href={builder(id)} linkAs={Link} icon="edit">
              {editable ? t('edit') : t('editFaq')}
            </DropdownMenuLinkItem>
            {isTemplate ? (
              <DropdownMenuItem icon="add_circle" onSelect={() => duplicate(false)}>
                {t('useTemplate')}
              </DropdownMenuItem>
            ) : (
              <>
                <DropdownMenuItem icon="content_copy" onSelect={() => duplicate(false)}>
                  {t('duplicate')}
                </DropdownMenuItem>
                <DropdownMenuItem icon="bookmark" onSelect={() => duplicate(true)}>
                  {t('saveAsTemplate')}
                </DropdownMenuItem>
              </>
            )}
          </>
        ) : null}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
