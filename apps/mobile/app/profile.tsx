// Profil & Trust Score (F-C12 / C4.1): skor 0–100 + efeknya (instant, premium, cap & hold per tier), statistik,
// sanksi + banding sekali, riwayat skor; edit nama & foto (≤ 1 MB, diperkecil ke 512 px). Sama dengan /profile web.
import * as ImageManipulator from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';
import { useRouter } from 'expo-router';
import { useState } from 'react';
import { Image, Linking, Modal, Platform as RN, Pressable, View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { num } from '@clipper/clipper-lib/pure';
import { formatAmount } from '@clipper/clipper-lib/units';
import { formatCompact, formatDate, formatNumber, initials } from '@clipper/ui/format';
import { useAuth } from '@/auth';
import { appealSanction, profile, saveProfile, useLoad } from '@/data';
import { haptic } from '@/haptics';
import { useErrorText } from '@/i18n';
import { useTheme } from '@/theme';
import { AppealButton } from '@/ui/appeal';
import { Alert, Badge, Button, Card, EmptyState, Field, Icon, ProgressBar, Row, Txt, type IconName } from '@/ui/core';
import { OfflineBanner } from '@/ui/offline';
import { Screen } from '@/ui/screen';
import { useToast } from '@/ui/toast';

function Stat({ icon, label, value, hint }: { icon: IconName; label: string; value: string; hint?: string }) {
  const { c } = useTheme();
  return (
    <Card style={{ flex: 1, minWidth: 150 }} padding={14}>
      <Row gap={6}>
        <Icon name={icon} size={16} color={c.muted} />
        <Txt variant="caption" tone="muted">{label}</Txt>
      </Row>
      <Txt variant="h5">{value}</Txt>
      {hint ? <Txt variant="caption" tone="muted">{hint}</Txt> : null}
    </Card>
  );
}

function EditProfile({ name, avatar, onSaved }: { name: string; avatar: string | null; onSaved: () => void }) {
  const t = useTranslations('clipper.profile.edit');
  const tm = useTranslations('clipper.mobile');
  const err = useErrorText();
  const toast = useToast();
  const { c } = useTheme();
  const { claims } = useAuth();
  const [open, setOpen] = useState(false);
  const [value, setValue] = useState(name);
  const [photo, setPhoto] = useState<{ uri: string; mime: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const pick = async () => {
    const r = await ImagePicker.launchImageLibraryAsync({ mediaTypes: ['images'], allowsEditing: true, aspect: [1, 1], quality: 0.9 });
    if (r.canceled || !r.assets[0]) return;
    // Perkecil di perangkat → ≤ 1 MB (batas bucket avatars) tanpa minta user memotong sendiri.
    const ctx = ImageManipulator.ImageManipulator.manipulate(r.assets[0].uri).resize({ width: 512 });
    const img = await ctx.renderAsync();
    const out = await img.saveAsync({ format: ImageManipulator.SaveFormat.JPEG, compress: 0.82 });
    setPhoto({ uri: out.uri, mime: 'image/jpeg' });
  };
  const save = async () => {
    setBusy(true);
    setError(null);
    const r = await saveProfile(claims!.sub, { displayName: value, photo });
    setBusy(false);
    if (!r.ok) return haptic.error(), setError(r.code);
    haptic.success();
    toast({ tone: 'success', title: t('saved') });
    setOpen(false);
    setPhoto(null);
    onSaved();
  };
  const shown = photo?.uri ?? avatar;
  return (
    <>
      <Button size="sm" variant="secondary" icon="edit" onPress={() => (setValue(name), setOpen(true))}>{t('cta')}</Button>
      <Modal visible={open} animationType="slide" presentationStyle={RN.OS === 'ios' ? 'pageSheet' : undefined} onRequestClose={() => setOpen(false)}>
        <Screen>
          <Row style={{ justifyContent: 'space-between' }}>
            <Txt variant="h5" accessibilityRole="header">{t('title')}</Txt>
            <Button variant="link" onPress={() => setOpen(false)}>{tm('cancel')}</Button>
          </Row>
          <Txt variant="bodyS" tone="text2">{t('description')}</Txt>
          {error ? <Alert tone="danger">{error === 'invalid:avatar_size' ? t('photoTooBig') : error === 'invalid:avatar_type' ? t('photoType') : err(error)}</Alert> : null}
          <Pressable accessibilityRole="button" accessibilityLabel={t('photo')} onPress={pick} style={{ alignSelf: 'center', alignItems: 'center', gap: 8 }}>
            {shown ? (
              <Image source={{ uri: shown }} style={{ width: 96, height: 96, borderRadius: 48 }} />
            ) : (
              <View style={{ width: 96, height: 96, borderRadius: 48, backgroundColor: c.primarySoft, alignItems: 'center', justifyContent: 'center' }}>
                <Icon name="photo_camera" size={32} color={c.primarySoftFg} />
              </View>
            )}
            <Txt variant="label" weight="700" tone="link">{t('photo')}</Txt>
            <Txt variant="caption" tone="muted">{t('photoHelper')}</Txt>
          </Pressable>
          <Field label={t('name')} value={value} onChangeText={setValue} maxLength={50} />
          <Button full loading={busy} disabled={!value.trim()} onPress={save}>{t('save')}</Button>
        </Screen>
      </Modal>
    </>
  );
}

export default function Profile() {
  const t = useTranslations('clipper.profile');
  const tm = useTranslations('clipper.mobile');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const { c, radius } = useTheme();
  const { claims } = useAuth();
  const uid = claims!.sub;
  const data = useLoad(() => profile(uid), [uid], `profile:${uid}`);
  const p = data.data;
  const name = p?.me?.display_name || p?.me?.username || claims?.email || '';
  const idrTotal = num(p?.earnings.find((e) => e.code === 'IDR')?.total ?? 0);
  return (
    <Screen title={t('title')} refreshing={data.loading && !!p} onRefresh={data.reload} banner={<OfflineBanner load={data} />}>
      {data.error && !p ? <EmptyState icon="wifi_off" title={err(data.error)} action={{ label: tm('refresh'), onPress: data.reload }} /> : null}
      {p ? (
        <>
          <Card style={{ flexDirection: 'row', alignItems: 'center', gap: 14 }}>
            {p.avatar ? (
              <Image source={{ uri: p.avatar }} style={{ width: 56, height: 56, borderRadius: 28 }} />
            ) : (
              <View style={{ width: 56, height: 56, borderRadius: 28, backgroundColor: c.primarySoft, alignItems: 'center', justifyContent: 'center' }}>
                <Txt variant="h6" style={{ color: c.primarySoftFg }}>{initials(name || '?')}</Txt>
              </View>
            )}
            <View style={{ flex: 1 }}>
              <Txt variant="h5" numberOfLines={1}>{name}</Txt>
              {p.me?.username ? <Txt variant="bodyS" tone="muted">@{p.me.username}</Txt> : null}
              {p.me?.created_at ? <Txt variant="caption" tone="muted">{t('since', { date: formatDate(p.me.created_at, locale) })}</Txt> : null}
            </View>
            {p.me?.status && p.me.status !== 'active' ? (
              <Badge tone="danger">{t(`status.${p.me.status}` as 'status.suspended')}</Badge>
            ) : (
              <EditProfile name={p.me?.display_name ?? ''} avatar={p.avatar} onSaved={data.reload} />
            )}
          </Card>

          <View style={{ backgroundColor: c.navy, borderRadius: radius.card, padding: 18, gap: 10 }}>
            <Row style={{ justifyContent: 'space-between', alignItems: 'flex-end' }}>
              <View>
                <Txt variant="caption" style={{ color: 'rgba(255,255,255,0.7)' }}>{t('trust')}</Txt>
                <Txt style={{ color: '#ffffff', fontSize: 40, lineHeight: 44 }} weight="800">
                  {String(p.score)}
                  <Txt variant="body" style={{ color: 'rgba(255,255,255,0.6)' }}>/100</Txt>
                </Txt>
              </View>
              <Icon name="workspace_premium" size={36} color="rgba(255,255,255,0.8)" filled />
            </Row>
            <ProgressBar value={p.score / 100} tone={p.score >= 70 ? 'primary' : p.score >= 40 ? 'warn' : 'danger'} accessibilityLabel={t('trust')} />
            <Txt variant="caption" style={{ color: 'rgba(255,255,255,0.7)' }}>{t('trustHint')}</Txt>
          </View>

          <Card>
            <Txt variant="h6">{t('effectsTitle')}</Txt>
            {p.effects.map((e) => (
              <Row key={e.key} gap={12} style={{ flexWrap: 'nowrap', alignItems: 'flex-start' }}>
                <View style={{ width: 32, height: 32, borderRadius: 16, alignItems: 'center', justifyContent: 'center', backgroundColor: e.ok ? c.successBg : e.ok === null ? c.primarySoft : c.subtle }}>
                  <Icon name={e.ok ? 'check' : e.ok === null ? 'trending_up' : 'lock'} size={16} color={e.ok ? c.successFg : e.ok === null ? c.primarySoftFg : c.muted} />
                </View>
                <View style={{ flex: 1 }}>
                  <Txt variant="bodyS" weight="700">{e.ok !== null && e.key !== 'instant' ? t(`effects.${e.key}.tier` as 'effects.cap.tier', e.vars) : t(`effects.${e.key}.title` as 'effects.instant.title', e.vars)}</Txt>
                  <Txt variant="caption" tone="muted">{t(`effects.${e.key}.body` as 'effects.instant.body', { ...e.vars, score: p.score })}</Txt>
                </View>
              </Row>
            ))}
          </Card>

          <Row gap={12} style={{ alignItems: 'stretch' }}>
            <Stat icon="visibility" label={t('views')} value={formatCompact(num(p.stats.total_views), locale)} />
            <Stat icon="movie" label={t('clips')} value={formatNumber(num(p.stats.clips), locale)} hint={t('campaigns', { n: num(p.stats.campaigns) })} />
            <Stat
              icon="check_circle"
              label={t('approval')}
              value={p.stats.approval_rate == null ? '—' : `${formatNumber(num(p.stats.approval_rate), locale, { maximumFractionDigits: 1 })}%`}
              hint={t('approvalHint', { approved: num(p.stats.approved), rejected: num(p.stats.rejected) })}
            />
            <Stat icon="payments" label={t('earning')} value={formatAmount(idrTotal, { code: 'IDR', unit_label: 'Rp' }, locale)} hint={t('earningHint')} />
          </Row>

          {p.earnings.filter((e) => e.code !== 'IDR').length ? (
            <Card>
              <Txt variant="h6">{t('otherEarnings')}</Txt>
              {p.earnings
                .filter((e) => e.code !== 'IDR')
                .map((e) => {
                  const unit = { code: String(e.code), unit_label: String(e.unit_label ?? ''), decimals: num(e.decimals) };
                  return (
                    <Row key={String(e.reward_type_id)} style={{ justifyContent: 'space-between' }}>
                      <Txt variant="bodyS" tone="text2">{unit.unit_label || unit.code}</Txt>
                      <Txt variant="bodyS" weight="700">{formatAmount(num(e.total), unit, locale)}</Txt>
                    </Row>
                  );
                })}
            </Card>
          ) : null}

          {p.sanctions.length ? (
            <Card>
              <Txt variant="h6">{t('sanctionsTitle')}</Txt>
              {p.sanctions.map((x) => (
                <View key={x.id} style={{ gap: 6, borderTopWidth: 1, borderColor: c.border, paddingTop: 10 }}>
                  <Row gap={8}>
                    <Txt variant="bodyS" weight="700">{t(`sanctions.${x.kind}` as 'sanctions.warning')}</Txt>
                    <Txt variant="caption" tone="muted">{x.created_at ? formatDate(x.created_at, locale) : ''}</Txt>
                  </Row>
                  {x.reason ? <Txt variant="caption" tone="text2">{x.reason}</Txt> : null}
                  {x.decision ? (
                    <Txt variant="caption" tone="text2">{`${t(`appealResult.${x.decision}` as 'appealResult.upheld')}${x.decision_note ? ` — ${x.decision_note}` : ''}`}</Txt>
                  ) : x.appealed_at ? (
                    <Txt variant="caption" tone="muted">{t('appealPending')}</Txt>
                  ) : (
                    <AppealButton kind="profile" min={10} send={(m) => appealSanction(x.id!, m)} onDone={data.reload} />
                  )}
                </View>
              ))}
            </Card>
          ) : null}

          <Card>
            <Txt variant="h6">{t('historyTitle')}</Txt>
            {p.events.length ? (
              p.events.map((e) => {
                const d = num(e.delta);
                return (
                  <Row key={e.id} gap={12} style={{ flexWrap: 'nowrap' }}>
                    <Txt variant="body" weight="800" tone={d > 0 ? 'successFg' : 'dangerFg'} style={{ width: 48 }}>{d > 0 ? `+${d}` : `−${Math.abs(d)}`}</Txt>
                    <Txt variant="bodyS" style={{ flex: 1 }}>{t(`reasons.${e.reason}` as 'reasons.approved')}</Txt>
                    <Txt variant="caption" tone="muted">{e.created_at ? formatDate(e.created_at, locale) : ''}</Txt>
                  </Row>
                );
              })
            ) : (
              <EmptyState icon="history" title={t('historyEmpty')} body={t('historyEmptyBody')} />
            )}
            <Txt variant="caption" tone="muted">{t('appealNote')}</Txt>
            {p.support ? <Button variant="link" size="sm" onPress={() => Linking.openURL(p.support!)}>{t('contactSupport')}</Button> : null}
          </Card>

          <Button full variant="secondary" icon="leaderboard" onPress={() => router.push('/leaderboard')}>{t('toLeaderboard')}</Button>
        </>
      ) : null}
    </Screen>
  );
}
