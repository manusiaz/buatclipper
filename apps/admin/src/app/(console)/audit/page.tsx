import type { Metadata } from 'next';
import Link from 'next/link';
import { getLocale, getTranslations } from 'next-intl/server';
import { coreServer, requireAdmin } from '@clipper/auth/server';
import { Alert, EmptyState, formatDateTime, PageHeader, Pagination, Table, TBody, TD, TH, THead, TR, type UiLocale } from '@clipper/ui';
import { isUuid, param, rows, uniq, type SearchParams } from '@/lib/data';
import { FilterBar } from '@/features/shared/filter-bar';
import { JsonView } from '@/features/shared/json-view';
import { rolesFor } from '@/features/shell/nav';

export async function generateMetadata(): Promise<Metadata> {
  return { title: (await getTranslations('admin'))('nav.audit') };
}

const PAGE = 50;

// F-A11: ops.audit_logs core (RLS: admin_super). Log akses PII identity (member.audit_logs) belum punya view api.
export default async function AuditPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  await requireAdmin(...rolesFor('audit'));
  const [t, locale, sp, db] = await Promise.all([getTranslations('admin'), getLocale(), searchParams, coreServer('admin')]);
  const loc = locale as UiLocale;
  const action = param(sp, 'action');
  const target = param(sp, 'target');
  const actor = param(sp, 'actor');
  const from = param(sp, 'from');
  const to = param(sp, 'to');
  const page = Math.max(1, Number(param(sp, 'page')) || 1);

  let q = db.from('audit_logs').select('id, actor_id, action, target, before, after, at', { count: 'exact' }).order('at', { ascending: false })
    .range((page - 1) * PAGE, page * PAGE - 1);
  if (/^[a-z_.]+$/.test(action)) q = q.like('action', `${action}%`);
  if (target) q = q.ilike('target', `%${target.replace(/[%_]/g, '')}%`);
  if (isUuid(actor)) q = q.eq('actor_id', actor);
  if (/^\d{4}-\d{2}-\d{2}$/.test(from)) q = q.gte('at', `${from}T00:00:00+07:00`);
  if (/^\d{4}-\d{2}-\d{2}$/.test(to)) q = q.lte('at', `${to}T23:59:59.999+07:00`);
  const res = await q;
  const logs = rows(res);
  const actors = new Map(rows(await db.from('profiles').select('id, username').in('id', uniq(logs.map((l) => l.actor_id)))).map((p) => [p.id, p.username]));
  const qs = new URLSearchParams(Object.entries({ action, target, actor, from, to }).filter(([, v]) => v));
  const href = (p: number) => `/audit?${new URLSearchParams([...qs, ['page', String(p)]])}`;

  return (
    <>
      <PageHeader title={t('audit.title')} description={t('audit.description')} />
      <Alert tone="info" className="mb-5">
        {t('audit.identityGap')}
      </Alert>
      <FilterBar
        submitLabel={t('form.apply')}
        resetHref="/audit"
        resetLabel={t('form.reset')}
        filters={[
          { kind: 'text', name: 'action', label: t('audit.action'), value: action, placeholder: 'config.' },
          { kind: 'text', name: 'target', label: t('audit.target'), value: target, placeholder: 'campaign:' },
          { kind: 'text', name: 'actor', label: t('audit.actor'), value: actor, placeholder: 'uuid' },
          { kind: 'date', name: 'from', label: t('audit.from'), value: from },
          { kind: 'date', name: 'to', label: t('audit.to'), value: to },
        ]}
      />
      {logs.length === 0 ? (
        <EmptyState icon="history" tone="neutral" title={t('audit.empty')} />
      ) : (
        <Table
          card
          caption={t('audit.title')}
          footer={(res.count ?? 0) > PAGE ? <Pagination page={page} pageCount={Math.ceil((res.count ?? 0) / PAGE)} getHref={href} linkAs={Link} /> : undefined}
        >
          <THead>
            <TR>
              <TH>{t('audit.at')}</TH>
              <TH>{t('audit.actor')}</TH>
              <TH>{t('audit.action')}</TH>
              <TH>{t('audit.target')}</TH>
              <TH>{t('audit.change')}</TH>
            </TR>
          </THead>
          <TBody>
            {logs.map((l) => (
              <TR key={l.id}>
                <TD muted className="whitespace-nowrap">{formatDateTime(l.at!, loc)}</TD>
                <TD>
                  {l.actor_id ? (
                    <Link href={`/audit?actor=${l.actor_id}`} className="text-link hover:underline">
                      {actors.get(l.actor_id) ? `@${actors.get(l.actor_id)}` : l.actor_id.slice(0, 8)}
                    </Link>
                  ) : (
                    <span className="text-muted">{t('audit.system')}</span>
                  )}
                </TD>
                <TD className="font-mono text-caption">{l.action}</TD>
                <TD className="max-w-48 font-mono text-caption break-all">{l.target}</TD>
                <TD className="min-w-64">
                  <details>
                    <summary className="cursor-pointer text-caption font-semibold text-link focus-ring">{t('audit.showChange')}</summary>
                    <div className="mt-2 grid grid-cols-1 gap-2 sm:grid-cols-2">
                      <div>
                        <p className="text-overline text-muted">{t('audit.before')}</p>
                        <JsonView value={l.before} max={20} />
                      </div>
                      <div>
                        <p className="text-overline text-muted">{t('audit.after')}</p>
                        <JsonView value={l.after} max={20} />
                      </div>
                    </div>
                  </details>
                </TD>
              </TR>
            ))}
          </TBody>
        </Table>
      )}
    </>
  );
}
