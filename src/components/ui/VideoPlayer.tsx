import React from 'react';
import { StyleProp, ViewStyle } from 'react-native';
import { VideoView, useVideoPlayer } from 'expo-video';

interface Props {
  uri: string;
  style?: StyleProp<ViewStyle>;
  contentFit?: 'contain' | 'cover' | 'fill';
  nativeControls?: boolean;
  autoPlay?: boolean;
  muted?: boolean;
  loop?: boolean;
}

/**
 * Wrapper de expo-video que reemplaza <Video> de expo-av (deprecado en SDK 54).
 * Usa useVideoPlayer internamente para simplificar el uso.
 */
export default function VideoPlayer({
  uri,
  style,
  contentFit = 'contain',
  nativeControls = false,
  autoPlay = false,
  muted = false,
  loop = false,
}: Props) {
  const player = useVideoPlayer(uri, (p) => {
    p.muted = muted;
    p.loop  = loop;
    if (autoPlay) p.play();
  });

  return (
    <VideoView
      player={player}
      style={style}
      contentFit={contentFit}
      nativeControls={nativeControls}
    />
  );
}
