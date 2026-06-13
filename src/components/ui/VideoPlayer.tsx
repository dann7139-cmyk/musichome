import { Audio } from 'expo-av';
import React, { useEffect, useState } from 'react';
import { ActivityIndicator, StyleProp, StyleSheet, View, ViewStyle } from 'react-native';
import { VideoView, useVideoPlayer } from 'expo-video';

interface Props {
  uri: string;
  style?: StyleProp<ViewStyle>;
  contentFit?: 'contain' | 'cover' | 'fill';
  nativeControls?: boolean;
  autoPlay?: boolean;
  muted?: boolean;
  loop?: boolean;
  startTime?: number;   // segundos — el player busca este punto al arrancar
}

export default function VideoPlayer({
  uri,
  style,
  contentFit = 'contain',
  nativeControls = false,
  autoPlay = false,
  muted = false,
  loop = false,
  startTime = 0,
}: Props) {
  const [loading, setLoading] = useState(true);

  // Activa el modo de audio para que el video suene aunque el teléfono
  // esté en silencio (iOS) o el canal de audio esté en media (Android).
  useEffect(() => {
    if (!muted) {
      Audio.setAudioModeAsync({
        playsInSilentModeIOS: true,
        staysActiveInBackground: false,
      }).catch(() => {});
    }
  }, [muted]);

  const player = useVideoPlayer({ uri, useCaching: true }, (p) => {
    p.muted = muted;
    p.loop  = loop;
    if (startTime > 0) p.currentTime = startTime;
    if (autoPlay) p.play();
  });

  useEffect(() => {
    const sub = player.addListener('statusChange', ({ status }) => {
      if (status !== 'loading') setLoading(false);
    });
    return () => sub.remove();
  }, [player]);

  return (
    <View style={[{ backgroundColor: '#000' }, style]}>
      <VideoView
        player={player}
        style={StyleSheet.absoluteFillObject}
        contentFit={contentFit}
        nativeControls={nativeControls}
      />
      {loading && (
        <View style={st.loader} pointerEvents="none">
          <ActivityIndicator size="large" color="#00E676" />
        </View>
      )}
    </View>
  );
}

const st = StyleSheet.create({
  loader: {
    ...StyleSheet.absoluteFillObject,
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.55)',
  },
});
