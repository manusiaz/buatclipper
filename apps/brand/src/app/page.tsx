import Link from 'next/link';
import type { Metadata } from 'next';
import { getTranslations } from 'next-intl/server';
import { coreServer, requireBrand } from '@clipper/auth/server';
import { Avatar, Badge, Button, Card, EmptyState, Icon, PageHeader, StatusBadge } from '@clipper/ui';
import { PlainShell } from '@/features/shell/plain-shell';
import { myName } from '@/features/shell/me';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('brand.picker'))('title') };
}

export default async function OrgPickerPage() {
  const { claims } = await requireBrand();
  const core = await coreServer();
  const [t, name, { data: orgs }, { data: mine }] = await Promise.all([
    getTranslations('brand'),
    myName(claims.email),
    core.from('organizations').select('id, name, status, is_agency, org_type').order('name'),
    core.from('org_members').select('org_id, role').eq('user_id', claims.sub),
  ]);
  const roles = new Map((mine ?? []).map((m) => [m.org_id, m.role]));
  const list = (orgs ?? []).filter((o) => o.id && o.name);

  return (
    <PlainShell name={name} email={claims.email}>
      <PageHeader
        title={t('picker.title')}
        description={t('picker.description')}
        actions={list.length ? <Button href="/new" linkAs={Link} iconLeft="add">{t('picker.create')}</Button> : null}
      />
      {list.length === 0 ? (
        <Card padding="lg">
          <EmptyState
            icon="storefront"
            title={t('picker.emptyTitle')}
            body={t('picker.emptyBody')}
            action={{ label: t('picker.create'), href: '/new', linkAs: Link, icon: 'add' }}
          />
        </Card>
      ) : (
        <ul className="grid gap-3 sm:grid-cols-2">
          {list.map((o) => {
            const role = roles.get(o.id);
            return (
              <li key={o.id}>
                <Card interactive padding="none" className="h-full">
                  <Link href={`/${o.id}/campaigns`} className="flex h-full items-center gap-3 rounded-card p-4 focus-ring">
                    <Avatar name={o.name!} size={44} shape="square" />
                    <span className="flex min-w-0 flex-1 flex-col gap-1.5">
                      <span className="truncate text-h6 text-ink">{o.name}</span>
                      <span className="flex flex-wrap items-center gap-1.5">
                        <StatusBadge kind="org" status={o.status ?? ''} label={t(`orgStatus.${o.status ?? 'pending_verification'}`)} size="sm" />
                        {role ? (
                          <Badge size="sm" tone="outline">{t(`roles.${role}`)}</Badge>
                        ) : (
                          <Badge size="sm" tone="primary" icon="groups">{t('picker.viaAgency')}</Badge>
                        )}
                        {o.is_agency ? <Badge size="sm" tone="premium">{t('picker.agency')}</Badge> : null}
                      </span>
                    </span>
                    <Icon name="chevron_right" className="text-muted" />
                  </Link>
                </Card>
              </li>
            );
          })}
        </ul>
      )}
    </PlainShell>
  );
}
