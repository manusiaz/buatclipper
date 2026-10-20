'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { hosts, kycUrl } from '@clipper/auth';
import { coreServer, requireBrand } from '@clipper/auth/server';
import { getOrgContext, isUuid, type OrgRole } from '@/lib/org';
import { fail, type Result } from '@/lib/result';

export type CreateOrgState = { error?: string; field?: string } | null;

const text = (f: FormData, k: string) => String(f.get(k) ?? '').trim();

/** B1.4 api.create_org → /<org>/campaigns; perorangan yang belum KYC → accounts/kyc?next=… */
export async function createOrg(_prev: CreateOrgState, form: FormData): Promise<CreateOrgState> {
  const { claims } = await requireBrand();
  const type = text(form, 'org_type') === 'perorangan' ? 'perorangan' : 'badan';
  const name = text(form, 'name');
  if (name.length < 2 || name.length > 100) return { error: 'invalid:name', field: 'name' };
  const npwp = text(form, 'npwp').replace(/\D/g, '');
  if (type === 'badan') {
    if (!text(form, 'legal_name')) return { error: 'invalid:legal_name', field: 'legal_name' };
    if (!/^\d{15,16}$/.test(npwp)) return { error: 'invalid:npwp', field: 'npwp' };
    if (!text(form, 'address')) return { error: 'invalid:address', field: 'address' };
  }
  const core = await coreServer();
  const { data: id, error } = await core.rpc('create_org', {
    p_name: name,
    p_org_type: type,
    p_is_agency: form.get('is_agency') === 'on',
    ...(type === 'badan' ? { p_legal_name: text(form, 'legal_name'), p_npwp: npwp, p_address: text(form, 'address') } : {}),
  });
  if (error || !id) return { error: error?.message ?? 'generic', field: error?.message?.startsWith('invalid:') ? error.message.slice(8) : undefined };
  revalidatePath('/');
  if (type === 'perorangan' && claims.kyc !== 'approved') redirect(kycUrl(`${hosts.brand}/${id}/campaigns`));
  redirect(`/${id}/campaigns`);
}

/** B2.1 link undangan anggota; token hanya tampil sekali. */
export async function createInvite(orgId: string, role: OrgRole): Promise<Result<{ url: string }>> {
  const { core } = await getOrgContext(orgId);
  const { data, error } = await core.rpc('create_org_invite', { p_org: orgId, p_role: role });
  if (error || !data) return fail(error);
  revalidatePath(`/${orgId}/team`);
  return { ok: true, url: `${hosts.accounts}/invite/${data}` };
}

/** B2.3 tautan agency. Dari sisi agency: request/revoke; dari sisi klien: approve/reject/revoke. */
export async function linkAgency(orgId: string, agency: string, client: string, action: 'request' | 'approve' | 'reject' | 'revoke'): Promise<Result> {
  const { core } = await getOrgContext(orgId);
  if (!isUuid(agency) || !isUuid(client)) return { ok: false, error: 'not_found:org' };
  const { error } = await core.rpc('link_agency', { p_agency: agency, p_client: client, p_action: action });
  if (error) return fail(error);
  revalidatePath(`/${orgId}/settings`);
  revalidatePath('/');
  return { ok: true };
}

/** B1.5/F-B01 api.update_org: data legal org verified berubah → verifikasi ulang (dicek ulang di DB). */
export async function updateOrg(orgId: string, input: { name: string; legal_name: string; npwp: string; address: string }): Promise<Result> {
  const { core, org } = await getOrgContext(orgId);
  const { error } = await core.rpc('update_org', {
    p_org: orgId,
    p_name: input.name.trim(),
    ...(org.org_type === 'badan' ? { p_legal_name: input.legal_name.trim(), p_npwp: input.npwp.replace(/\D/g, ''), p_address: input.address.trim() } : {}),
  });
  if (error) return fail(error);
  revalidatePath(`/${orgId}`, 'layout');
  revalidatePath('/');
  return { ok: true };
}
