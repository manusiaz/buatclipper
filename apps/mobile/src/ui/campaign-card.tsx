// Kartu campaign native = CampaignCard web (F-C03): rate terbesar paling menonjol, sisa budget dalam views + bar,
// contoh cuan, deadline relatif, CTA 6 state (Catatan UX KitaClip: state terblokir bukan tombol primer).
import { Image, Pressable, View } from 'react-native';
import { cardLabels, type CampaignCtaState } from '@clipper/ui/campaign-labels';
import { earningFor, formatCompact, formatIDR, formatRelative, type UiLocale } from '@clipper/ui/format';
import type { CardData } from '../data';
import { useTheme } from '../theme';
import { Badge, Button, Card, Icon, PlatformChip, PlatformIcon, ProgressBar, Row, Txt } from './core';

const EXAMPLE_VIEWS = 10_000;
const BLOCKED: Partial<Record<CampaignCtaState, 'groups' | 'local_fire_department' | 'schedule' | 'lock'>> = {
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
  reasonText,
}: {
  card: CardData;
  locale: UiLocale;
  onOpen: () => void;
  onCta?: () => void;
  reasonText?: string | null;
}) {
  const { c, radius } = useTheme();
  const L = cardLabels(locale);
  const top = [...card.rates].sort((a, b) => b.ratePer1k - a.ratePer1k)[0];
  const state = card.ctaState as CampaignCtaState | undefined;
  const blocked = state ? BLOCKED[state] : undefined;
  return (
    <Card padding={0} style={{ overflow: 'hidden', gap: 0 }}>
      <Pressable accessibilityRole="link" accessibilityLabel={card.title} onPress={onOpen}>
        <View style={{ aspectRatio: 16 / 9, backgroundColor: c.navy, justifyContent: 'space-between', padding: 10 }}>
          {card.coverSrc ? <Image source={{ uri: card.coverSrc }} style={{ position: 'absolute', inset: 0 } as never} resizeMode="cover" accessibilityIgnoresInvertColors /> : null}
          <Row gap={6}>
            {card.pinned ? <Badge icon="keep">{L.pinned}</Badge> : null}
            {card.isNew ? <Badge tone="primary">{L.isNew}</Badge> : null}
          </Row>
          {!card.coverSrc ? (
            <View style={{ alignSelf: 'center' }}>
              <Icon name="movie" size={34} color="rgba(255,255,255,0.55)" />
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
              <Txt variant="caption" tone="text2" numberOfLines={1} style={{ flexShrink: 1 }}>
                {card.brand.name}
              </Txt>
              {card.brand.verified ? <Icon name="verified" size={14} color={c.primary} filled /> : null}
              {card.category ? <Txt variant="caption" tone="muted">· {card.category}</Txt> : null}
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
          {card.rates.length > 1 ? (
            <Row gap={10}>
              {card.rates.map((r) => (
                <Row key={r.platform} gap={4}>
                  <PlatformIcon platform={r.platform} size={13} color={c.text2} />
                  <Txt variant="caption" tone="text2">{formatIDR(r.ratePer1k, { locale })}</Txt>
                </Row>
              ))}
            </Row>
          ) : card.platforms[0] ? (
            <PlatformChip platform={card.platforms[0]} />
          ) : null}
          {card.budgetUsedRatio != null ? <ProgressBar value={card.budgetUsedRatio} tone={card.budgetUsedRatio > 0.9 ? 'danger' : 'primary'} /> : null}
          <Row style={{ justifyContent: 'space-between' }}>
            {card.remainingViews != null ? <Txt variant="caption" tone="text2">{L.viewsLeft(formatCompact(card.remainingViews, locale))}</Txt> : <View />}
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
            <View accessibilityRole="text" style={{ height: 44, borderRadius: radius.control, borderWidth: 1.5, borderStyle: 'dashed', borderColor: c.borderHover, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6 }}>
              <Icon name={blocked} size={18} color={c.text2} />
              <Txt variant="label" weight="700" tone="text2">{L.cta[state]}</Txt>
            </View>
          ) : (
            <Button full variant={state === 'claimed_not_submitted' ? 'ink' : 'primary'} icon={state === 'claimed_not_submitted' ? 'upload' : undefined} iconRight={state === 'can_claim' ? 'arrow_forward' : undefined} onPress={onCta ?? onOpen}>
              {L.cta[state]}
            </Button>
          )}
          {reasonText ? <Txt variant="caption" tone="muted" style={{ textAlign: 'center' }}>{reasonText}</Txt> : null}
        </View>
      ) : null}
    </Card>
  );
}
