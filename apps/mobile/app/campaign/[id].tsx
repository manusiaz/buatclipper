// F-C04–C06 / C1.6 native: detail campaign (teks dari detail-text.ts yang sama dengan web) + CTA claim / submit.
import * as Clipboard from 'expo-clipboard';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { Image, Linking, View } from 'react-native';
import { useLocale, useTranslations } from 'use-intl';
import { budgetUsedRatio, cardRates, fixKey, isPlatform, isUuid, maxViews } from '@clipper/clipper-lib/pure';
import { detailText } from '@clipper/clipper-lib/detail-text';
import { durationParts, earningFor, formatCompact, formatDateTime, formatIDR, formatNumber } from '@clipper/ui/format';
import type { Platform } from '@clipper/ui/platform-paths';
import { useAuth } from '@/auth';
import { campaignDetail, claimCampaign, useLoad } from '@/data';
import { useErrorText } from '@/i18n';
import { useTheme } from '@/theme';
import { Alert, Badge, Button, Card, EmptyState, Icon, PlatformChip, PlatformIcon, ProgressBar, Row, Txt } from '@/ui/core';
import { Screen } from '@/ui/screen';
import { openWeb } from '@/web';

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

function Countdown({ target, expired, locale }: { target: string; expired: string; locale: 'id' | 'en' }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);
  const ms = new Date(target).getTime() - now;
  if (ms <= 0) return <Txt variant="caption" weight="700">{expired}</Txt>;
  const p = durationParts(ms);
  // Format sama dengan <Countdown> web: "47 j 12 m" (jam total).
  return <Txt variant="caption" weight="700">{`${p.totalHours} ${locale === 'en' ? 'h' : 'j'} ${String(p.minutes).padStart(2, '0')} m`}</Txt>;
}

export default function Detail() {
  const { id, submit } = useLocalSearchParams<{ id: string; submit?: string }>();
  const t = useTranslations('clipper');
  const locale = useLocale() === 'en' ? 'en' : 'id';
  const err = useErrorText();
  const router = useRouter();
  const { c } = useTheme();
  const { claims } = useAuth();
  const data = useLoad(() => campaignDetail(claims!.sub, id), [claims?.sub, id]);
  const [claimError, setClaimError] = useState<string | null>(null);
  const [claiming, setClaiming] = useState(false);
  const [copied, setCopied] = useState(false);

  const d = data.data?.d;
  const openSubmit = () => d?.my.claim && router.push({ pathname: '/submit', params: { campaignId: d.campaign.id, claimId: d.my.claim.id } });
  useEffect(() => {
    if (submit === '1' && d?.cta_state === 'claimed_not_submitted') openSubmit();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [submit, d?.cta_state]);

  if (!isUuid(id)) return <Screen back><EmptyState icon="search" title={err('not_found')} /></Screen>;
  if (!data.data) {
    return (
      <Screen back title={t('detail.header')}>
        {data.error ? <EmptyState icon="wifi_off" title={err(data.error)} action={{ label: t('mobile.refresh'), onPress: data.reload }} /> : <Txt tone="muted">…</Txt>}
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
    state === 'not_eligible' && d!.cta_reason ? err(`not_eligible:${d!.cta_reason}`) : state && ['slots_full', 'budget_exhausted', 'deadline_passed'].includes(state) ? err(state) : null;
  const fix = state === 'not_eligible' ? fixKey(d!.cta_reason) : claimError ? fixKey(claimError) : null;
  const runFix = () =>
    fix === 'connect' ? router.push('/social') : fix === 'kyc' ? openWeb('accounts', '/kyc') : fix === 'onboarding' ? openWeb('accounts', '/onboarding') : router.push('/account');

  const claimNow = async () => {
    setClaimError(null);
    setClaiming(true);
    const r = await claimCampaign(camp.id);
    setClaiming(false);
    if (!r.ok) return setClaimError(r.code);
    await data.reload();
  };

  const footer =
    state === 'can_claim' ? (
      <Button full size="lg" iconRight="arrow_forward" loading={claiming} onPress={claimNow} testID="claim">
        {t('claim.cta')}
      </Button>
    ) : state === 'claimed_not_submitted' && d!.my.claim ? (
      <View style={{ gap: 6 }}>
        <Button full size="lg" variant="ink" icon="upload" onPress={openSubmit} testID="open-submit">
          {t('claim.submit')}
        </Button>
        <Row gap={4} style={{ justifyContent: 'center' }}>
          <Txt variant="caption" tone="muted">{t('claim.expiresIn')}</Txt>
          <Countdown target={d!.my.claim.expires_at} expired={t('claim.expired')} locale={locale} />
        </Row>
      </View>
    ) : (
      <View style={{ gap: 6 }}>
        <View style={{ height: 48, borderRadius: 12, borderWidth: 1.5, borderStyle: 'dashed', borderColor: c.borderHover, alignItems: 'center', justifyContent: 'center', flexDirection: 'row', gap: 6 }}>
          <Icon name="lock" size={18} color={c.text2} />
          <Txt variant="label" weight="700" tone="text2">{t(`cta.${state ?? 'not_eligible'}` as 'cta.not_eligible')}</Txt>
        </View>
        {reasonText ? <Txt variant="caption" tone="muted" style={{ textAlign: 'center' }}>{reasonText}</Txt> : null}
        {fix ? <Button variant="link" onPress={runFix}>{t(`fix.${fix}`)}</Button> : null}
      </View>
    );

  return (
    <Screen back title={t('detail.header')} refreshing={data.loading} onRefresh={data.reload} footer={footer}>
      <View style={{ aspectRatio: 16 / 9, borderRadius: 18, overflow: 'hidden', backgroundColor: c.navy, justifyContent: 'space-between', padding: 12 }}>
        {coverSrc ? <Image source={{ uri: coverSrc }} style={{ position: 'absolute', inset: 0 } as never} resizeMode="cover" /> : null}
        <Badge tone={camp.status === 'live' ? 'success' : 'neutral'}>{t(`status.campaign.${camp.status}` as 'status.campaign.live')}</Badge>
        <Row gap={6}>{platforms.map((p) => <PlatformIcon key={p} platform={p} size={16} color="#ffffff" />)}</Row>
      </View>
      {d!.brand ? (
        <Row gap={6} style={{ flexWrap: 'nowrap' }}>
          <Txt variant="caption" tone="text2" style={{ flexShrink: 1 }}>{d!.brand.name}</Txt>
          {d!.brand.verified ? <Icon name="verified" size={14} color={c.primary} filled /> : null}
        </Row>
      ) : null}
      <Txt variant="h4" accessibilityRole="header">{camp.title}</Txt>
      {camp.sponsored_label ? <Alert tone="warn">{t('detail.sponsored')}</Alert> : null}
      {claimError ? <Alert tone="danger" action={fix ? { label: t(`fix.${fix}`), onPress: runFix } : undefined}>{err(claimError)}</Alert> : null}

      <Card>
        <Txt variant="caption" tone="muted">{t('detail.topRate')}</Txt>
        {top ? (
          <Row gap={4} style={{ alignItems: 'baseline' }}>
            <Txt variant="h2">{formatIDR(top.ratePer1k, { locale })}</Txt>
            <Txt variant="caption" tone="muted">/1K views</Txt>
          </Row>
        ) : null}
        {top ? <Badge tone="success">{t('detail.example', { views: formatNumber(10_000, locale), amount: formatIDR(earningFor(10_000, top.ratePer1k), { locale }) })}</Badge> : null}
        {used !== undefined ? <ProgressBar value={used} tone={used > 0.9 ? 'danger' : 'primary'} /> : null}
        <Row style={{ justifyContent: 'space-between' }}>
          <Txt variant="caption" tone="text2">{views !== undefined ? t('detail.viewsLeft', { views: formatCompact(views, locale) }) : t('detail.noBudget')}</Txt>
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
        {d!.pools.filter((p) => p.max_per_clip != null).map((p) => (
          <Txt key={p.pool_id} variant="caption" tone="muted">{t('detail.cap', { amount: text.capText(p) })}</Txt>
        ))}
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
            <Icon name="check" size={16} color={c.primary} />
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
            <Button key={u} variant="link" icon="open_in_new" onPress={() => Linking.openURL(u)}>{u.replace(/^https:\/\//, '').slice(0, 48)}</Button>
          ))}
        </Card>
      ) : null}

      {d!.assets.some((a) => a.kind !== 'cover') ? (
        <Card>
          <Txt variant="h6">{t('detail.assets')}</Txt>
          {d!.assets
            .filter((a) => a.kind !== 'cover')
            .map((a) => {
              const href = a.kind === 'link' ? a.url : a.storage_path ? assetUrls.get(a.storage_path) : null;
              return href ? (
                <Button key={a.id} variant="link" icon={a.kind === 'link' ? 'open_in_new' : 'download'} onPress={() => Linking.openURL(href)}>
                  {a.kind === 'link' ? t('detail.open') : t('detail.download')}
                </Button>
              ) : (
                <Txt key={a.id} variant="caption" tone="muted">{t('detail.unavailable')}</Txt>
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
            <View key={i} style={{ gap: 2 }}>
              <Txt variant="label" weight="700">{f.q}</Txt>
              <Txt variant="bodyS" tone="text2">{f.a}</Txt>
            </View>
          ))}
        </Card>
      ) : null}

      {d!.my.submissions.length ? (
        <Card>
          <Row style={{ justifyContent: 'space-between' }}>
            <Txt variant="h6">{t('detail.mySubmissions')}</Txt>
            <Button variant="link" size="sm" onPress={() => router.push('/tasks')}>{t('detail.allTasks')}</Button>
          </Row>
          {d!.my.submissions.map((s) => (
            <Row key={s.id} style={{ justifyContent: 'space-between', flexWrap: 'nowrap' }}>
              <Badge>{t(`status.submission.${s.status}` as 'status.submission.tracking')}</Badge>
              <Txt variant="caption" tone="muted">{t('detail.views', { n: formatCompact(s.counted_views, locale) })}</Txt>
            </Row>
          ))}
        </Card>
      ) : null}
      <PlatformsUsed platforms={platforms} />
    </Screen>
  );
}

function PlatformsUsed({ platforms }: { platforms: Platform[] }) {
  return <Row gap={6}>{platforms.map((p) => <PlatformChip key={p} platform={p} />)}</Row>;
}
