// F-C04–C06 / C1.6 native: detail campaign (teks dari clipper-lib/detail-text yang sama dengan web) + CTA claim /
// submit. Dipakai route /campaign/[id] dan panel kanan list-detail (≥ 840 dp, DS Android window size "Expanded").
import * as Clipboard from 'expo-clipboard';
import { useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Image, Linking, Pressable, View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { budgetUsedRatio, cardRates, fixKey, httpsUrl, isPlatform, isUuid, maxViews } from '@clipper/clipper-lib/pure';
import { detailText } from '@clipper/clipper-lib/detail-text';
import { earningFor, formatCompact, formatDateTime, formatIDR, formatNumber, initials } from '@clipper/ui/format';
import type { Platform } from '@clipper/ui/platform-paths';
import { useAuth } from '../auth';
import { campaignDetail, categories, claimCampaign, useLoad } from '../data';
import { runFix } from '../fix';
import { haptic } from '../haptics';
import { useErrorText } from '../i18n';
import { useTheme } from '../theme';
import { Alert, Badge, Button, Card, EmptyState, Icon, PlatformChip, ProgressBar, Row, Txt, type IconName } from '../ui/core';
import { Countdown } from '../ui/countdown';
import { Embed } from '../ui/embed';
import { OfflineBanner } from '../ui/offline';
import { Screen } from '../ui/screen';
import { useToast } from '../ui/toast';

/** Brief markdown → baris sederhana (judul, butir, paragraf); app native tidak memuat renderer markdown penuh. */
function Brief({ source }: { source: string }) {
  return (
    <View style={{ gap: 6 }}>
      {source
        .split(/\n+/)
        .map((l) => l.trim())
        .filter(Boolean)
        .map((l, i) => {
          const plain = l.replace(/\*\*(.+?)\*\*/g, '$1').replace(/\[(.+?)\]\((.+?)\)/g, '$1 ($2)');
          if (/^#{1,6}\s/.test(l)) return <Txt key={i} variant="h6">{plain.replace(/^#+\s*/, '')}</Txt>;
          if (/^[-*]\s/.test(l)) return <Txt key={i} variant="bodyS" tone="text2">{'•  ' + plain.slice(2)}</Txt>;
          return <Txt key={i} variant="bodyS" tone="text2">{plain}</Txt>;
        })}
    </View>
  );
}

function Faq({ q, a }: { q: string; a: string }) {
  const { c } = useTheme();
  const [open, setOpen] = useState(false);
  return (
    <View style={{ borderTopWidth: 1, borderColor: c.border }}>
      <Pressable accessibilityRole="button" accessibilityState={{ expanded: open }} onPress={() => setOpen(!open)} style={{ minHeight: 48, flexDirection: 'row', alignItems: 'center', gap: 8, paddingVertical: 10 }}>
        <Txt variant="label" weight="700" style={{ flex: 1 }}>{q}</Txt>
        <Icon name={open ? 'keyboard_arrow_up' : 'keyboard_arrow_down'} size={22} color={c.muted} />
      </Pressable>
      {open ? <Txt variant="bodyS" tone="text2" style={{ paddingBottom: 12 }}>{a}</Txt> : null}
    </View>
  );
}

const BLOCKED_ICON: Record<string, IconName> = { slots_full: 'groups', budget_exhausted: 'local_fire_department', deadline_passed: 'schedule' };
const ASSET_ICON: Record<string, IconName> = { link: 'link', video: 'movie', image: 'image', audio: 'music_note' };

export function CampaignDetail({ id, submit, sharedUrl, embedded }: { id: string; submit?: boolean; sharedUrl?: string; embedded?: boolean }) {
  const t = useTranslations('clipper');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const toast = useToast();
  const { c, radius } = useTheme();
  const { claims } = useAuth();
  const uid = claims!.sub;
  const data = useLoad(() => campaignDetail(uid, id), [uid, id], `detail:${uid}:${id}`);
  const cats = useLoad(() => categories(locale), [locale], `categories:${locale}`);
  const [claimError, setClaimError] = useState<string | null>(null);
  const [claiming, setClaiming] = useState(false);
  const [copied, setCopied] = useState(false);

  const d = data.data?.d;
  const canSubmit = d?.cta_state === 'claimed_not_submitted' && d.my.claim?.status === 'open';
  const openSubmit = (url?: string) =>
    d?.my.claim && router.push({ pathname: '/submit', params: { campaignId: d.campaign.id, claimId: d.my.claim.id, ...(url ? { url } : {}) } });
  useEffect(() => {
    if ((submit || sharedUrl) && canSubmit) openSubmit(httpsUrl(sharedUrl) ?? undefined);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [submit, sharedUrl, canSubmit]);

  const title = embedded ? undefined : t('detail.header');
  if (!isUuid(id)) return <Screen title={title}><EmptyState icon="search" title={err('not_found')} /></Screen>;
  if (!data.data) {
    return (
      <Screen title={title}>
        {data.error ? (
          <EmptyState icon={data.error === 'not_found' ? 'search' : 'wifi_off'} title={err(data.error)} action={{ label: t('mobile.refresh'), onPress: data.reload }} />
        ) : (
          <Txt tone="muted">{t('mobile.loading')}</Txt>
        )}
      </Screen>
    );
  }

  const { coverSrc, terms, assetUrls } = data.data;
  const camp = d!.campaign;
  const platforms = camp.platforms.filter(isPlatform) as Platform[];
  const idr = new Map(d!.pools.map((p) => [p.reward_type_id, p.idr_value_per_unit]));
  const top = cardRates(d!.rules, platforms, idr).sort((a, b) => b.ratePer1k - a.ratePer1k)[0];
  const views = maxViews(d!.est_remaining_views);
  const used = budgetUsedRatio(d!.budget_idr, d!.remaining_idr);
  const text = detailText(d!, platforms, terms, locale, (k, v) => t(k as never, v as never));
  const when = (v: string | null) => (v ? `${formatDateTime(v, locale, { dateStyle: 'long', timeStyle: 'short' })} WIB` : '—');
  const state = d!.cta_state;
  const reasonText =
    state === 'not_eligible' && d!.cta_reason ? err(`not_eligible:${d!.cta_reason}`) : state && BLOCKED_ICON[state] ? err(state) : null;
  const fix = state === 'not_eligible' ? fixKey(d!.cta_reason) : claimError ? fixKey(claimError) : null;
  const category = camp.category_id ? (cats.data?.get(camp.category_id) ?? camp.category_id) : null;
  const files = d!.assets.filter((a) => a.kind !== 'cover');

  const claimNow = async () => {
    setClaimError(null);
    setClaiming(true);
    const r = await claimCampaign(camp.id);
    setClaiming(false);
    if (!r.ok) {
      haptic.error();
      return setClaimError(r.code);
    }
    haptic.success();
    toast({ tone: 'success', title: t('claim.success'), body: t('claim.successBody') });
    await data.reload();
  };

  const footer =
    state === 'can_claim' ? (
      <Button full size="lg" iconRight="arrow_forward" loading={claiming} onPress={claimNow} testID="claim">
        {claiming ? t('claim.claiming') : t('claim.cta')}
      </Button>
    ) : canSubmit ? (
      <View style={{ gap: 6 }}>
        <Button full size="lg" variant="ink" icon="upload" onPress={() => openSubmit()} testID="open-submit">
          {t('claim.submit')}
        </Button>
        <Row gap={4} style={{ justifyContent: 'center' }}>
          <Txt variant="caption" tone="muted">{t('claim.expiresIn')}</Txt>
          <Countdown target={d!.my.claim!.expires_at} />
        </Row>
      </View>
    ) : (
      <View style={{ gap: 6 }}>
        <View accessibilityRole="text" style={{ minHeight: 48, borderRadius: radius.control, borderWidth: 1.5, borderStyle: 'dashed', borderColor: c.borderHover, alignItems: 'center', justifyContent: 'center', flexDirection: 'row', gap: 6, paddingHorizontal: 12 }}>
          <Icon name={(state ? BLOCKED_ICON[state] : undefined) ?? 'lock'} size={18} color={c.text2} />
          <Txt variant="label" weight="700" tone="text2">{t(`cta.${state ?? 'not_eligible'}` as 'cta.not_eligible')}</Txt>
        </View>
        {reasonText ? <Txt variant="caption" tone="muted" style={{ textAlign: 'center' }}>{reasonText}</Txt> : null}
        {fix ? <Button variant="link" onPress={() => runFix(fix, router, camp.id)}>{t(`fix.${fix}`)}</Button> : null}
      </View>
    );

  return (
    <Screen title={title} refreshing={data.loading} onRefresh={data.reload} footer={footer} banner={<OfflineBanner load={data} />}>
      <View style={{ aspectRatio: 16 / 9, borderRadius: radius.card, overflow: 'hidden', backgroundColor: c.navy, justifyContent: 'space-between', padding: 12 }}>
        {coverSrc ? (
          <Image source={{ uri: coverSrc }} style={{ position: 'absolute', inset: 0 } as never} resizeMode="cover" accessibilityIgnoresInvertColors />
        ) : (
          <View style={{ position: 'absolute', inset: 0, alignItems: 'center', justifyContent: 'center' } as never}>
            <Icon name="movie" size={48} color="rgba(255,255,255,0.55)" />
          </View>
        )}
        <Row gap={6}>
          <Badge tone={camp.status === 'live' ? 'success' : 'neutral'}>{t(`status.campaign.${camp.status}` as 'status.campaign.live')}</Badge>
          {camp.visibility !== 'public' ? <Badge icon="lock">{t(`detail.visibility.${camp.visibility}` as 'detail.visibility.invite')}</Badge> : null}
        </Row>
        <Row gap={6}>
          {platforms.map((p) => (
            <PlatformChip key={p} platform={p} glass />
          ))}
        </Row>
      </View>
      {d!.brand || category ? (
        <Row gap={6} style={{ flexWrap: 'nowrap' }}>
          {d!.brand ? (
            <>
              <View style={{ width: 22, height: 22, borderRadius: 6, backgroundColor: c.primarySoft, alignItems: 'center', justifyContent: 'center' }}>
                <Txt variant="caption" weight="700" style={{ fontSize: 10, color: c.primarySoftFg }}>{initials(d!.brand.name)}</Txt>
              </View>
              <Txt variant="caption" weight="600" tone="text2" numberOfLines={1} style={{ flexShrink: 1 }}>{d!.brand.name}</Txt>
              {d!.brand.verified ? <Icon name="verified" size={14} color={c.primary} filled accessibilityLabel={t('detail.verifiedBrand')} /> : null}
            </>
          ) : null}
          {category ? <Txt variant="caption" tone="muted" numberOfLines={1}>{d!.brand ? `· ${category}` : category}</Txt> : null}
        </Row>
      ) : null}
      <Txt variant="h4" accessibilityRole="header">{camp.title}</Txt>
      {camp.sponsored_label ? (
        <Row gap={6}>
          <Icon name="info" size={16} color={c.warnFg} filled />
          <Txt variant="caption" weight="600" tone="warnFg">{t('detail.sponsored')}</Txt>
        </Row>
      ) : null}
      {claimError ? <Alert tone="danger" action={fix ? { label: t(`fix.${fix}`), onPress: () => runFix(fix, router, camp.id) } : undefined}>{err(claimError)}</Alert> : null}

      <Card>
        <Row style={{ justifyContent: 'space-between', alignItems: 'flex-end' }}>
          <View>
            <Txt variant="caption" tone="muted">{t('detail.topRate')}</Txt>
            <Row gap={4} style={{ alignItems: 'baseline' }}>
              <Txt variant="h2">{top ? formatIDR(top.ratePer1k, { locale }) : '—'}</Txt>
              <Txt variant="caption" tone="muted">/1K views</Txt>
            </Row>
          </View>
          {top ? <Badge tone="success">{t('detail.example', { views: formatNumber(10_000, locale), amount: formatIDR(earningFor(10_000, top.ratePer1k), { locale }) })}</Badge> : null}
        </Row>
        {used !== undefined ? <ProgressBar value={used} tone={used > 0.9 ? 'danger' : 'primary'} accessibilityLabel={t('detail.budgetUsed')} /> : null}
        <Row style={{ justifyContent: 'space-between' }}>
          <Txt variant="caption" weight="600" tone={used !== undefined && used >= 0.9 ? 'dangerFg' : 'text2'}>
            {views !== undefined ? t('detail.viewsLeft', { views: formatCompact(views, locale) }) : t('detail.noBudget')}
          </Txt>
          <Txt variant="caption" tone="muted">{t('detail.budgetLeft', { amount: formatIDR(d!.remaining_idr, { locale, compact: true }) })}</Txt>
        </Row>
      </Card>

      <Card>
        <Txt variant="h6">{t('detail.ratesTitle')}</Txt>
        {text.rateGroups.length ? (
          text.rateGroups.map((g) => (
            <View key={g.platform ?? 'all'} style={{ gap: 4 }}>
              <Txt variant="label" weight="600">{g.platform ? t(`platforms.${g.platform}` as 'platforms.tiktok') : t('detail.allPlatforms')}</Txt>
              {g.rules.flatMap((r) => text.describe(r)).map((line, i) => (
                <Txt key={i} variant="bodyS" tone="text2">{line}</Txt>
              ))}
            </View>
          ))
        ) : (
          <Txt variant="bodyS" tone="muted">{t('detail.noRates')}</Txt>
        )}
        {d!.clipper_fee_pct > 0 ? <Txt variant="bodyS" tone="muted">{t('detail.clipperFee', { pct: formatNumber(d!.clipper_fee_pct, locale) })}</Txt> : null}
        {d!.pools.some((p) => p.max_per_clip) ? (
          <View style={{ backgroundColor: c.subtle, borderRadius: radius.control, padding: 12, gap: 4 }}>
            {d!.pools.filter((p) => p.max_per_clip).map((p) => (
              <Txt key={p.pool_id} variant="caption" tone="text2">{t('detail.cap', { amount: text.capText(p) })}</Txt>
            ))}
          </View>
        ) : null}
        <Button variant="ghost" size="sm" icon="leaderboard" onPress={() => router.push({ pathname: '/leaderboard', params: { tab: 'campaign', campaign: camp.id } })}>
          {t('detail.leaderboard')}
        </Button>
      </Card>

      {text.tags.length ? (
        <Card>
          <Txt variant="h6">{t('detail.tagsTitle')}</Txt>
          <Row gap={6}>{text.tags.map((x) => <Badge key={x} tone="primary">{x}</Badge>)}</Row>
          <Button
            variant="secondary"
            icon={copied ? 'check_circle' : 'content_copy'}
            onPress={async () => {
              await Clipboard.setStringAsync(text.tags.join(' '));
              haptic.success();
              setCopied(true);
            }}
          >
            {copied ? t('copied') : t('detail.copyTags')}
          </Button>
        </Card>
      ) : null}

      <Card>
        <Txt variant="h6">{t('detail.reqTitle')}</Txt>
        {text.requirements.map((r) => (
          <Row key={r} gap={8} style={{ flexWrap: 'nowrap', alignItems: 'flex-start' }}>
            <Icon name="check_small" size={20} color={c.primary} />
            <Txt variant="bodyS" tone="text2" style={{ flex: 1 }}>{r}</Txt>
          </Row>
        ))}
      </Card>

      {camp.brief.trim() ? (
        <Card>
          <Txt variant="h6">{t('detail.briefTitle')}</Txt>
          <Brief source={camp.brief} />
        </Card>
      ) : null}

      {camp.dos.length ? (
        <Card>
          <Txt variant="h6">{t('detail.dos')}</Txt>
          {camp.dos.map((x, i) => (
            <Row key={i} gap={8} style={{ flexWrap: 'nowrap', alignItems: 'flex-start' }}>
              <Icon name="check_circle" size={18} color={c.success} filled />
              <Txt variant="bodyS" style={{ flex: 1 }}>{x}</Txt>
            </Row>
          ))}
        </Card>
      ) : null}
      {camp.donts.length ? (
        <Card>
          <Txt variant="h6">{t('detail.donts')}</Txt>
          {camp.donts.map((x, i) => (
            <Row key={i} gap={8} style={{ flexWrap: 'nowrap', alignItems: 'flex-start' }}>
              <Icon name="cancel" size={18} color={c.danger} filled />
              <Txt variant="bodyS" style={{ flex: 1 }}>{x}</Txt>
            </Row>
          ))}
        </Card>
      ) : null}

      {camp.example_urls.length ? (
        <Card>
          <Txt variant="h6">{t('detail.examples')}</Txt>
          {camp.example_urls.slice(0, 6).map((u) => (
            <Embed key={u} url={u} title={t('detail.exampleTitle')} openLabel={t('detail.openExample')} />
          ))}
        </Card>
      ) : null}

      {files.length ? (
        <Card>
          <Txt variant="h6">{t('detail.assets')}</Txt>
          {files.map((a) => {
            const href = a.url ?? (a.storage_path ? assetUrls.get(a.storage_path) : null);
            const name = a.url ?? a.storage_path?.split('/').at(-1) ?? a.kind;
            return (
              <Row key={a.id} gap={12} style={{ flexWrap: 'nowrap', borderWidth: 1, borderColor: c.border, borderRadius: radius.control, padding: 10 }}>
                <Icon name={ASSET_ICON[a.kind] ?? 'description'} size={20} color={c.muted} />
                <View style={{ flex: 1 }}>
                  <Txt variant="bodyS" weight="600" numberOfLines={1}>{name}</Txt>
                  <Txt variant="caption" tone="muted">
                    {t(`detail.assetKind.${a.kind}` as 'detail.assetKind.link')}
                    {a.size_bytes ? ` · ${formatCompact(a.size_bytes / 1_000_000, locale)} MB` : ''}
                  </Txt>
                </View>
                {href ? (
                  <Button size="sm" variant="secondary" icon={a.kind === 'link' ? undefined : 'download'} onPress={() => Linking.openURL(href)}>
                    {a.kind === 'link' ? t('detail.open') : t('detail.download')}
                  </Button>
                ) : (
                  <Txt variant="caption" tone="muted">{t('detail.unavailable')}</Txt>
                )}
              </Row>
            );
          })}
        </Card>
      ) : null}

      <Card>
        <Txt variant="h6">{t('detail.timeline')}</Txt>
        {[
          [t('detail.start'), when(camp.start_at)],
          [t('detail.deadline'), when(camp.submit_deadline)],
          [t('detail.viewWindow'), t('detail.viewWindowValue', { n: camp.view_window_days })],
          [t('detail.claimWindow'), t('detail.claimWindowValue')],
          ...(d!.my.claim?.status === 'open' ? [[t('detail.myClaim'), when(d!.my.claim.expires_at)]] : []),
        ].map(([k, v]) => (
          <Row key={k} style={{ justifyContent: 'space-between', flexWrap: 'nowrap' }}>
            <Txt variant="bodyS" tone="muted">{k}</Txt>
            <Txt variant="bodyS" weight="600" style={{ flexShrink: 1, textAlign: 'right' }}>{v}</Txt>
          </Row>
        ))}
      </Card>

      {camp.faq.length ? (
        <Card>
          <Txt variant="h6">{t('detail.faq')}</Txt>
          {camp.faq.map((f, i) => (
            <Faq key={i} q={f.q} a={f.a} />
          ))}
        </Card>
      ) : null}

      {d!.my.submissions.length ? (
        <Card>
          <Row style={{ justifyContent: 'space-between' }}>
            <Txt variant="h6">{t('detail.mySubmissions')}</Txt>
            <Button variant="link" size="sm" onPress={() => router.push('/clips')}>{t('detail.allTasks')}</Button>
          </Row>
          {d!.my.submissions.map((s) => (
            <Pressable key={s.id} accessibilityRole="link" onPress={() => s.url && Linking.openURL(s.url)} style={{ minHeight: 44, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
              <Badge tone={s.status === 'tracking' || s.status === 'locked' ? 'success' : s.status.startsWith('rejected') || s.status === 'forfeited' ? 'danger' : 'neutral'}>
                {t(`status.submission.${s.status}` as 'status.submission.tracking')}
              </Badge>
              <Txt variant="caption" tone="muted">{t('detail.views', { n: formatCompact(s.counted_views, locale) })}</Txt>
              {s.url ? <Icon name="open_in_new" size={16} color={c.muted} /> : null}
            </Pressable>
          ))}
        </Card>
      ) : null}
    </Screen>
  );
}
