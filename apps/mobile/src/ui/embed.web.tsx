// Web (uji): iframe embed resmi, sama dengan EmbedFrame app web.
import { createElement } from 'react';
import { Linking, View } from 'react-native';
import { toEmbedUrl } from '@clipper/ui/embed';
import { Button } from './core';

export function Embed({ url, title }: { url: string; title: string; openLabel: string }) {
  const info = toEmbedUrl(url);
  if (!info) return <Button variant="link" icon="open_in_new" onPress={() => Linking.openURL(url)}>{url.replace(/^https?:\/\//, '').slice(0, 48)}</Button>;
  const [w, h] = info.aspect.split(' / ').map(Number) as [number, number];
  return (
    <View style={{ width: '100%', maxWidth: w < h ? 340 : undefined, alignSelf: 'center', aspectRatio: w / h, borderRadius: 16, overflow: 'hidden' }}>
      {createElement('iframe', { src: info.src, title, loading: 'lazy', allow: 'encrypted-media; picture-in-picture', sandbox: 'allow-scripts allow-same-origin allow-popups', style: { border: 0, width: '100%', height: '100%' } })}
    </View>
  );
}
