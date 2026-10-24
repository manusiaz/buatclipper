// Contoh video campaign: embed resmi platform (toEmbedUrl, sama dengan EmbedFrame web). Dimuat saat ditap supaya
// kuota data tidak habis di layar detail; link yang tidak bisa di-embed → tombol buka di aplikasinya.
import { useState } from 'react';
import { Linking, Pressable, View } from 'react-native';
import { WebView } from 'react-native-webview';
import { toEmbedUrl } from '@clipper/ui/embed';
import { platformLabels } from '@clipper/ui/platform-paths';
import { useTheme } from '../theme';
import { Button, Icon, PlatformIcon, Txt } from './core';

export function Embed({ url, title, openLabel }: { url: string; title: string; openLabel: string }) {
  const { c, radius } = useTheme();
  const info = toEmbedUrl(url);
  const [on, setOn] = useState(false);
  if (!info) return <Button variant="link" icon="open_in_new" onPress={() => Linking.openURL(url)}>{url.replace(/^https?:\/\//, '').slice(0, 48)}</Button>;
  const [w, h] = info.aspect.split(' / ').map(Number) as [number, number];
  return (
    <View style={{ width: '100%', maxWidth: w < h ? 340 : undefined, alignSelf: 'center', aspectRatio: w / h, borderRadius: radius.card, overflow: 'hidden', backgroundColor: c.navy }}>
      {on ? (
        <WebView
          source={{ uri: info.src }}
          allowsInlineMediaPlayback
          mediaPlaybackRequiresUserAction={false}
          allowsFullscreenVideo
          setSupportMultipleWindows={false}
          onShouldStartLoadWithRequest={(r) => r.url.startsWith(info.src.split('?')[0]!) || r.navigationType !== 'click'}
          accessibilityLabel={title}
          style={{ flex: 1, backgroundColor: c.navy }}
        />
      ) : (
        <Pressable accessibilityRole="button" accessibilityLabel={title} onPress={() => setOn(true)} style={{ flex: 1, alignItems: 'center', justifyContent: 'center', gap: 10 }}>
          <Icon name="play_circle" size={52} color="#ffffff" filled />
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
            <PlatformIcon platform={info.platform} size={14} color="#ffffff" />
            <Txt variant="caption" weight="600" style={{ color: '#ffffff' }}>{platformLabels[info.platform]}</Txt>
          </View>
          <Pressable accessibilityRole="link" onPress={() => Linking.openURL(url)} hitSlop={8}>
            <Txt variant="caption" style={{ color: 'rgba(255,255,255,0.8)', textDecorationLine: 'underline' }}>{openLabel}</Txt>
          </Pressable>
        </Pressable>
      )}
    </View>
  );
}
