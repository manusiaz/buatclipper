// Banding sekali (submisi ditolak di Clip, sanksi akun di Profil — §12): sheet sistem (iOS pageSheet, Android slide).
import { useState } from 'react';
import { KeyboardAvoidingView, Modal, Platform, View } from 'react-native';
import { useTranslations } from 'use-intl';
import { haptic } from '../haptics';
import { useErrorText } from '../i18n';
import { useTheme } from '../theme';
import { Alert, Button, Field, Row, Txt } from './core';
import { useToast } from './toast';

export function AppealButton({ kind, send, onDone, min = 1 }: { kind: 'tasks' | 'profile'; send: (msg: string) => Promise<{ ok: true } | { ok: false; code: string }>; onDone: () => void; min?: number }) {
  const t = useTranslations(kind === 'tasks' ? 'clipper.tasks.appeal' : 'clipper.profile.appeal');
  const tc = useTranslations('clipper');
  const err = useErrorText();
  const toast = useToast();
  const { c, radius } = useTheme();
  const [open, setOpen] = useState(false);
  const [text, setText] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const submit = async () => {
    setBusy(true);
    setError(null);
    const r = await send(text);
    setBusy(false);
    if (!r.ok) {
      haptic.error();
      return setError(r.code);
    }
    haptic.success();
    toast({ tone: 'success', title: t('sent') });
    setOpen(false);
    setText('');
    onDone();
  };
  return (
    <>
      <Button size="sm" variant="secondary" icon="gavel" onPress={() => setOpen(true)}>{t('cta')}</Button>
      <Modal visible={open} animationType="slide" presentationStyle={Platform.OS === 'ios' ? 'pageSheet' : undefined} transparent={Platform.OS !== 'ios'} onRequestClose={() => setOpen(false)}>
        <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={{ flex: 1, justifyContent: Platform.OS === 'ios' ? 'flex-start' : 'flex-end', backgroundColor: Platform.OS === 'ios' ? c.canvas : 'rgba(10,18,38,0.32)' }}>
          <View style={{ backgroundColor: c.surface, borderTopLeftRadius: radius.card, borderTopRightRadius: radius.card, padding: 20, gap: 14, flex: Platform.OS === 'ios' ? 1 : undefined }}>
            {Platform.OS !== 'ios' ? <View style={{ alignSelf: 'center', width: 32, height: 4, borderRadius: 2, backgroundColor: c.borderStrong }} /> : null}
            <Row style={{ justifyContent: 'space-between' }}>
              <Txt variant="h5" accessibilityRole="header">{t('title')}</Txt>
              <Button variant="link" onPress={() => setOpen(false)}>{tc('mobile.cancel')}</Button>
            </Row>
            <Txt variant="bodyS" tone="text2">{t('description')}</Txt>
            {error ? <Alert tone="danger">{err(error)}</Alert> : null}
            <Field label={t('label')} helper={t('helper')} value={text} onChangeText={setText} multiline numberOfLines={5} maxLength={1000} style={{ minHeight: 120, textAlignVertical: 'top' }} />
            <Button full loading={busy} disabled={text.trim().length < min} onPress={submit}>{t('submit')}</Button>
          </View>
        </KeyboardAvoidingView>
      </Modal>
    </>
  );
}
