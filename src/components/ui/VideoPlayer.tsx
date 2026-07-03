import { Audio } from 'expo-av';
import React, { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, StyleProp, StyleSheet, Text, View, ViewStyle } from 'react-native';
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
  onEnd?: () => void;   // se llama cuando el video termina (solo sin loop)
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
  onEnd,
}: Props) {
  const [loading, setLoading] = useState(true);
  const [hasError, setHasError] = useState(false);

  // Ref para evitar re-registrar el listener cuando el padre re-renderiza
  const onEndRef = useRef(onEnd);
  useEffect(() => { onEndRef.current = onEnd; }, [onEnd]);

  useEffect(() => {
    setLoading(true);
    setHasError(false);
  }, [uri]);

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
    const statusSub = player.addListener('statusChange', ({ status }) => {
      if (status === 'error') {
        console.warn('VideoPlayer: failed to load', uri);
        setHasError(true);
      }
      if (status !== 'loading') setLoading(false);
    });
    const endSub = player.addListener('playToEnd', () => {
      onEndRef.current?.();
    });
    return () => {
      statusSub.remove();
      endSub.remove();
    };
  }, [player]);

  return (
    <View style={[{ backgroundColor: '#000' }, style]}>
      <VideoView
        player={player}
        style={StyleSheet.absoluteFillObject}
        contentFit={contentFit}
        nativeControls={nativeControls}
      />
      {loading && !hasError && (
        <View style={st.loader} pointerEvents="none">
          <ActivityIndicator size="large" color="#00E676" />
        </View>
      )}
      {hasError && (
        <View style={st.error} pointerEvents="none">
          <Text style={st.errorText}>No se pudo cargar el video</Text>
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
  error: {
    ...StyleSheet.absoluteFillObject,
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.7)',
  },
  errorText: {
    color: '#ff5252',
    fontSize: 13,
  },
});
