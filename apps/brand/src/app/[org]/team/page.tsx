import type { Metadata } from 'next';
import { getLocale, getTranslations } from 'next-intl/server';
import { Alert, Avatar, Badge, Card, CardContent, CardHeader, CardTitle, EmptyState, PageHeader, Table, TBody, TD, TH, THead, TR, formatDate } from '@clipper/ui';
import { InviteDialog } from '@/features/org/invite-dialog';
import { getOrgContext } from '@/lib/org';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('brand.nav'))('team') };
}

export default async function TeamPage({ params }: { params: Promise<{ org: string }> }) {
  const { org: orgId } = await params;
  const { core, role, direct, claims } = await getOrgContext(orgId);
  const owner = role === 'brand_owner' && direct;
  const [t, locale, { data: members }, invitesRes] = await Promise.all([
    getTranslations('brand'),
    getLocale(),
    core.from('org_members').select('user_id, role, created_at').eq('org_id', orgId).order('created_at'),
    owner ? core.from('org_invites').select('id, role, expires_at, accepted_by, accepted_at, created_at').eq('org_id', orgId).order('created_at', { ascending: false }).limit(50) : null,
  ]);
  const loc = locale === 'en' ? 'en' : 'id';
  const ids = (members ?? []).map((m) => m.user_id).filter((x): x is string => !!x);
  const acceptedIds = (invitesRes?.data ?? []).map((i) => i.accepted_by).filter((x): x is string => !!x);
  const all = [...new Set([...ids, ...acceptedIds])];
  const { data: profiles } = all.length ? await core.from('profiles').select('id, username, display_name, avatar_path').in('id', all) : { data: [] };
  const prof = new Map((profiles ?? []).map((p) => [p.id, p]));
  const now = Date.now();

  return (
    <>
      <PageHeader title={t('team.title')} description={t('team.description')} actions={owner ? <InviteDialog orgId={orgId} /> : null} />
      {!owner ? <Alert tone="info" className="mb-4">{direct ? t('team.ownerOnly') : t('team.viaAgency')}</Alert> : null}
      <div className="flex flex-col gap-5">
        <Table caption={t('team.members', { count: ids.length })} captionVisible>
          <THead>
            <TR>
              <TH>{t('team.colMember')}</TH>
              <TH>{t('team.colRole')}</TH>
              <TH>{t('team.colSince')}</TH>
            </TR>
          </THead>
          <TBody>
            {(members ?? []).map((m) => {
              const p = m.user_id ? prof.get(m.user_id) : undefined;
              const name = p?.display_name || p?.username || '—';
              return (
                <TR key={m.user_id}>
                  <TD>
                    <span className="flex max-w-[320px] items-center gap-3">
                      <Avatar name={name} size={32} />
                      <span className="flex min-w-0 flex-col">
                        <span className="truncate font-semibold text-ink">
                          {name}
                          {m.user_id === claims.sub ? <span className="ml-1.5 text-caption font-normal text-muted">{t('team.you')}</span> : null}
                        </span>
                        {p?.username ? <span className="truncate text-caption text-muted">@{p.username}</span> : null}
                      </span>
                    </span>
                  </TD>
                  <TD><Badge tone={m.role === 'brand_owner' ? 'primary' : 'neutral'}>{t(`roles.${m.role ?? 'brand_viewer'}`)}</Badge></TD>
                  <TD muted>{m.created_at ? formatDate(m.created_at, loc) : '—'}</TD>
                </TR>
              );
            })}
          </TBody>
        </Table>

        {owner ? (
          <Card padding="none">
            <CardHeader className="px-5 pt-5"><CardTitle>{t('team.invites')}</CardTitle></CardHeader>
            <CardContent className="px-0 pb-2">
              {(invitesRes?.data ?? []).length === 0 ? (
                <EmptyState compact icon="link" title={t('team.noInvites')} className="pb-4" />
              ) : (
                <ul className="divide-y divide-border">
                  {(invitesRes?.data ?? []).map((i) => {
                    const state = i.accepted_at ? 'accepted' : i.expires_at && new Date(i.expires_at).getTime() <= now ? 'expired' : 'pending';
                    const by = i.accepted_by ? prof.get(i.accepted_by) : undefined;
                    return (
                      <li key={i.id} className="flex flex-wrap items-center gap-x-3 gap-y-1 px-5 py-3 text-body-s">
                        <Badge tone="outline">{t(`roles.${i.role ?? 'brand_viewer'}`)}</Badge>
                        <Badge tone={state === 'accepted' ? 'success' : state === 'pending' ? 'warn' : 'neutral'}>{t(`team.inviteState.${state}`)}</Badge>
                        <span className="text-muted">
                          {state === 'accepted'
                            ? t('team.acceptedBy', { name: by?.username ? `@${by.username}` : '—', date: formatDate(i.accepted_at!, loc) })
                            : t('team.expires', { date: i.expires_at ? formatDate(i.expires_at, loc) : '—' })}
                        </span>
                      </li>
                    );
                  })}
                </ul>
              )}
            </CardContent>
          </Card>
        ) : null}
        <p className="text-caption text-muted">{t('team.manageNote')}</p>
      </div>
    </>
  );
}
