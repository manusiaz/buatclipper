'use server';

import { coreServer, getAuth, invokeFunction, requireAdmin } from '@clipper/auth/server';
import { identityApi } from '@clipper/db-identity';
import { settle, settleFn, text, optText, type ActionResult } from '@/lib/action';
import { dbError } from '@/lib/errors';
import { isUuid } from '@/lib/data';

const PLATFORM_ROLES = ['admin_super', 'admin_ops', 'admin_moderator', 'admin_finance', 'admin_support'] as const;
type Role = (typeof PLATFORM_ROLES)[number];
const ORG_ROLES = ['brand_owner', 'brand_manager', 'brand_finance', 'brand_viewer'] as const;

async function identity() {
  return identityApi((await getAuth('admin')).supabase).schema('api');
}

async function recordKyc(userId: string, decision: 'approve' | 'reject', reason: string | null, message: string | null) {
  const db = await coreServer('admin');
  return db.rpc('record_review', {
    p_target_type: 'kyc',
    p_target_id: userId,
    p_decision: decision,
    p_reason: reason ?? undefined,
    p_message: message ?? undefined,
  });
}

/**
 * A2.1: keputusan KYC di identity dulu (admin_kyc_decision, E-05), lalu core record_review target kyc (catatan tanpa PII +
 * notifikasi kyc.approved/rejected). Kalau langkah core gagal, keputusan identity sudah tersimpan → kyc_notify_failed
 * (halaman menawarkan "Catat & kabari" yang hanya memanggil core).
 */
export async function kycDecision(userId: string, decision: 'approve' | 'reject', fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_moderator');
  const reason = optText(fd, 'reason');
  if (decision === 'reject' && !reason) return { ok: false, error: 'invalid:reason' };
  const { error } = await (await identity()).rpc('admin_kyc_decision', {
    p_user_id: userId,
    p_decision: decision === 'approve' ? 'approved' : 'rejected',
    p_reason: reason ?? undefined,
  });
  if (error) return { ok: false, error: error.code === 'P0002' ? 'kyc_not_pending' : dbError(error) };
  const core = await recordKyc(userId, decision, reason, optText(fd, 'message'));
  if (core.error) return { ok: false, error: 'kyc_notify_failed' };
  return settle(null, '/users');
}

export async function kycNotify(userId: string, decision: 'approve' | 'reject', reason: string | null): Promise<ActionResult> {
  await requireAdmin('admin_moderator');
  const { error } = await recordKyc(userId, decision, reason, null);
  return settle(error, '/users');
}

/** F-A07 ban_duration lewat identity admin-auth (refresh token ditolak). Status E-01 core tidak ikut berubah. */
export async function banUser(userId: string, fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_moderator');
  const choice = text(fd, 'duration');
  const hours = text(fd, 'hours');
  const duration = choice === 'custom' ? `${Number(hours) | 0}h` : choice;
  const r = await invokeFunction('identity', 'admin-auth', { action: 'ban_user', user_id: userId, duration }, 'admin');
  return settleFn(r, '/users');
}

export async function unbanUser(userId: string): Promise<ActionResult> {
  await requireAdmin('admin_moderator');
  return settleFn(await invokeFunction('identity', 'admin-auth', { action: 'unban_user', user_id: userId }, 'admin'), '/users');
}

/** A2.2: verify | reject | suspend lewat manage_org saja (record_review target org memakai logika yang sama → notifikasi ganda). */
export async function orgDecision(orgId: string, action: 'verify' | 'reject' | 'suspend', fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_ops');
  const db = await coreServer('admin');
  const { error } = await db.rpc('manage_org', {
    p_org: orgId,
    p_action: action,
    p_params: { reason: optText(fd, 'reason'), message: optText(fd, 'message'), note: optText(fd, 'note') },
  });
  return settle(error, '/users');
}

/** Fee custom org (persen + biaya instant); kosongkan = kembali ke fee global. */
export async function orgSetFee(orgId: string, fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_ops');
  const params: Record<string, unknown> = {};
  if (fd.get('clear') != null) params.clear = true;
  else for (const k of ['mgmt_fee_pct', 'admin_fee_pct', 'clipper_fee_pct', 'instant_withdraw_fee']) if (text(fd, k)) params[k] = Number(text(fd, k));
  const db = await coreServer('admin');
  const { error } = await db.rpc('manage_org', { p_org: orgId, p_action: 'set_fee', p_params: params as never });
  return settle(error, '/users');
}

async function addMember(orgId: string, userId: string, role: string) {
  const db = await coreServer('admin');
  return db.rpc('manage_org', { p_org: orgId, p_action: 'add_member', p_params: { user_id: userId, role } });
}

export async function orgAddMember(orgId: string, fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_ops');
  const userId = text(fd, 'user_id');
  const role = text(fd, 'role');
  if (!isUuid(userId) || !ORG_ROLES.includes(role as never)) return { ok: false, error: 'invalid:user_id' };
  const { error } = await addMember(orgId, userId, role);
  return settle(error, '/users');
}

/** Paket managed: undang PIC (admin-auth invite_user) lalu tulis keanggotaan org (manage_org add_member). */
export async function orgInvitePic(orgId: string, orgName: string, fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_ops');
  const role = text(fd, 'role');
  if (!ORG_ROLES.includes(role as never)) return { ok: false, error: 'invalid:role' };
  const inv = await invokeFunction<{ user_id: string }>('identity', 'admin-auth', { action: 'invite_user', email: text(fd, 'email'), org_hint: orgName.slice(0, 100) }, 'admin');
  if (!inv.ok) return { ok: false, error: inv.error };
  const { error } = await addMember(orgId, inv.data.user_id, role);
  return settle(error, '/users');
}

/** E-27 hanya admin_super. Undang admin = akun identity baru (invite) + role. */
export async function adminInvite(fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_super');
  const role = text(fd, 'role') as Role;
  if (!PLATFORM_ROLES.includes(role)) return { ok: false, error: 'invalid:role' };
  const inv = await invokeFunction<{ user_id: string }>('identity', 'admin-auth', { action: 'invite_user', email: text(fd, 'email') }, 'admin');
  if (!inv.ok) return { ok: false, error: inv.error };
  const { error } = await (await identity()).rpc('admin_set_role', { p_user_id: inv.data.user_id, p_role: role, p_grant: true });
  return settle(error, '/users');
}

export async function adminSetRole(fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_super');
  const userId = text(fd, 'user_id');
  const role = text(fd, 'role') as Role;
  if (!isUuid(userId) || !PLATFORM_ROLES.includes(role)) return { ok: false, error: 'invalid:user_id' };
  const { error } = await (await identity()).rpc('admin_set_role', { p_user_id: userId, p_role: role, p_grant: text(fd, 'grant') !== 'revoke' });
  return settle(error, '/users');
}

export async function adminResetMfa(fd: FormData): Promise<ActionResult> {
  await requireAdmin('admin_super');
  const userId = text(fd, 'user_id');
  if (!isUuid(userId)) return { ok: false, error: 'invalid:user_id' };
  return settleFn(await invokeFunction('identity', 'admin-auth', { action: 'reset_mfa', user_id: userId }, 'admin'), '/users');
}
