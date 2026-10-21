// Kartu campaign native = CampaignCard web (F-C03): rate terbesar paling menonjol, sisa budget dalam views + bar,
// contoh cuan, deadline relatif, CTA 6 state (Catatan UX KitaClip: state terblokir bukan tombol primer, tapi selalu
// ada aksi berikutnya "perbaiki"). Tekan lama = menu cepat (DS iOS Motion 26 #6).
import { Image, Pressable, View } from 'react-native';
import { useTranslations } from 'use-intl';
import { cardLabels, type CampaignCtaState } from '@clipper/ui/campaign-labels';
import { earningFor, formatCompact, formatIDR, formatRelative, initials, type UiLocale } from '@clipper/ui/format';
import type { CardData } from '../data';
import { useTheme } from '../theme';
import { Badge, Button, Card, Icon, PlatformChip, PlatformIcon, ProgressBar, Row, Txt, type IconName } from './core';
import { Countdown } from './countdown';

const EXAMPLE_VIEWS = 10_000;
const BLOCKED: Partial<Record<CampaignCtaState, IconName>> = {
  slots_full: 'groups',
  budget_exhausted: 'local_fire_department',
  deadline_passed: 'schedule',
  not_eligible: 'lock',
};

export function CampaignCardView({
  card,
  locale,
  onOpen,
  onCta,
  onLongPress,
  reasonText,
  fix,
  selected,
}: {
  card: CardData;
  locale: UiLocale;
  onOpen: () => void;
  onCta?: () => void;
  onLongPress?: () => void;
  reasonText?: string | null;
  /** Aksi perbaiki untuk not_eligible (hubungkan akun, KYC, onboarding, Trust Score). */
  fix?: { label: string; onPress: () => void } | null;
  /** Dipilih di panel list-detail (tablet). */
  selected?: boolean;
}) {
  const { c, radius } = useTheme();
  const t = useTranslations('clipper');
  const L = cardLabels(locale);
  const top = [...card.rates].sort((a, b) => b.ratePer1k - a.ratePer1k)[0];
  const ratesDiffer = new Set(card.rates.map((r) => r.ratePer1k)).size > 1;
  const state = card.ctaState as CampaignCtaState | undefined;
  const blocked = state ? BLOCKED[state] : undefined;
  const hot = card.budgetUsedRatio != null && card.budgetUsedRatio >= 0.9;
  return (
    <Card padding={0} style={{ overflow: 'hidden', gap: 0, opacity: blocked ? 0.92 : 1, borderWidth: selected ? 2 : undefined, borderColor: selected ? c.primary : undefined }}>
      <Pressable accessibilityRole="link" accessibilityLabel={card.title} accessibilityHint={onLongPress ? t('mobile.longPressHint') : undefined} onPress={onOpen} onLongPress={onLongPress} delayLongPress={500} android_ripple={{ color: c.border }}>
        <View style={{ aspectRatio: 16 / 9, backgroundColor: c.navy, justifyContent: 'space-between', padding: 10 }}>
          {card.coverSrc ? <Image source={{ uri: card.coverSrc }} style={{ position: 'absolute', inset: 0, opacity: blocked ? 0.7 : 1 } as never} resizeMode="cover" accessibilityIgnoresInvertColors /> : null}
          <Row gap={6}>
            {card.pinned ? <Badge icon="keep">{L.pinned}</Badge> : null}
            {card.isNew ? <Badge tone="primary">{L.isNew}</Badge> : null}
            {card.status !== 'live' ? <Badge>{t(`status.campaign.${card.status}` as 'status.campaign.live')}</Badge> : null}
          </Row>
          {!card.coverSrc ? (
            <View style={{ alignSelf: 'center' }}>
              <Icon name={card.categoryIcon} size={34} color="rgba(255,255,255,0.55)" />
            </View>
          ) : null}
          <Row gap={6}>
            {card.platforms.map((p) => (
              <PlatformIcon key={p} platform={p} size={14} color="#ffffff" />
            ))}
          </Row>
        </View>
        <View style={{ padding: 14, gap: 8 }}>
          {card.brand ? (
            <Row gap={6} style={{ flexWrap: 'nowrap' }}>
              <View style={{ width: 20, height: 20, borderRadius: 6, backgroundColor: c.primarySoft, alignItems: 'center', justifyContent: 'center' }}>
                <Txt variant="caption" weight="700" style={{ fontSize: 9, color: c.primarySoftFg }}>{initials(card.brand.name)}</Txt>
              </View>
              <Txt variant="caption" tone="text2" numberOfLines={1} style={{ flexShrink: 1 }}>
                {card.brand.name}
              </Txt>
              {card.brand.verified ? <Icon name="verified" size={14} color={c.primary} filled /> : null}
              {card.category ? <Txt variant="caption" tone="muted" numberOfLines={1}>· {card.category}</Txt> : null}
            </Row>
          ) : null}
          <Txt variant="h6" numberOfLines={2}>
            {card.title}
          </Txt>
          {top ? (
            <Row gap={4} style={{ alignItems: 'baseline' }}>
              <Txt variant="h4">{formatIDR(top.ratePer1k, { locale })}</Txt>
              <Txt variant="caption" tone="muted">{L.perViews}</Txt>
            </Row>
          ) : null}
          {ratesDiffer ? (
            <Row gap={10}>
              {card.rates.map((r) => (
                <Row key={r.platform} gap={4}>
                  <PlatformIcon platform={r.platform} size={13} color={c.text2} />
                  <Txt variant="caption" tone="text2">{formatIDR(r.ratePer1k, { locale })}</Txt>
                </Row>
              ))}
            </Row>
          ) : card.platforms.length === 1 ? (
            <PlatformChip platform={card.platforms[0]!} />
          ) : null}
          {card.budgetUsedRatio != null ? <ProgressBar value={card.budgetUsedRatio} tone={hot ? 'danger' : 'primary'} /> : null}
          <Row style={{ justifyContent: 'space-between' }}>
            {card.remainingViews != null ? (
              <Txt variant="caption" weight={hot ? '700' : undefined} tone={hot ? 'dangerFg' : 'text2'}>{L.viewsLeft(formatCompact(card.remainingViews, locale))}</Txt>
            ) : (
              <View />
            )}
            {card.deadline ? (
              <Row gap={4}>
                <Icon name="schedule" size={14} color={c.muted} />
                <Txt variant="caption" tone="muted">{formatRelative(card.deadline, Date.now(), locale)}</Txt>
              </Row>
            ) : null}
          </Row>
          {top ? (
            <View style={{ backgroundColor: c.successBg, borderRadius: radius.chip, paddingHorizontal: 10, paddingVertical: 6, flexDirection: 'row', gap: 6, alignItems: 'center' }}>
              <Icon name="payments" size={15} color={c.successFg} />
              <Txt variant="caption" weight="600" tone="successFg">{L.example(formatCompact(EXAMPLE_VIEWS, locale), formatIDR(earningFor(EXAMPLE_VIEWS, top.ratePer1k), { locale }))}</Txt>
            </View>
          ) : null}
        </View>
      </Pressable>
      {state ? (
        <View style={{ paddingHorizontal: 14, paddingBottom: 14, gap: 6 }}>
          {blocked ? (
            <View accessibilityRole="text" style={{ minHeight: 44, borderRadius: radius.control, borderWidth: 1.5, borderStyle: 'dashed', borderColor: c.borderHover, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6, paddingHorizontal: 10 }}>
              <Icon name={blocked} size={18} color={c.text2} />
              <Txt variant="label" weight="700" tone="text2">{L.cta[state]}</Txt>
            </View>
          ) : (
            <Button full variant={state === 'claimed_not_submitted' ? 'ink' : 'primary'} icon={state === 'claimed_not_submitted' ? 'upload' : undefined} iconRight={state === 'can_claim' ? 'arrow_forward' : undefined} onPress={onCta ?? onOpen}>
              {L.cta[state]}
            </Button>
          )}
          {state === 'claimed_not_submitted' && card.claimExpiresAt ? (
            <Row gap={4} style={{ justifyContent: 'center' }}>
              <Txt variant="caption" tone="muted">{L.claimExpires}</Txt>
              <Countdown target={card.claimExpiresAt} />
            </Row>
          ) : null}
          {reasonText ? <Txt variant="caption" tone="muted" style={{ textAlign: 'center' }}>{reasonText}</Txt> : null}
          {fix ? (
            <Button variant="link" size="sm" onPress={fix.onPress} accessibilityLabel={fix.label}>
              {fix.label}
            </Button>
          ) : null}
        </View>
      ) : null}
    </Card>
  );
}
