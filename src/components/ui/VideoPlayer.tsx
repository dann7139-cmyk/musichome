import { setAudioModeAsync } from 'expo-audio';
import React, { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, StyleProp, StyleSheet, Text, View, ViewStyle } from 'react-native';
import { VideoView, useVideoPlayer } from 'expo-video';

interface Props {
  uri: string;
  style?: StyleProp<ViewStyle>;
  contentFit?: 'contain' | 'cover' | 'fill';
  nativeControls?: boolean;
  autoPlay?: boolean;
  posterFrame?: boolean; // arranca y pausa de inmediato solo para mostrar el primer cuadro como miniatura
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
  posterFrame = false,
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

  // Activa el modo de audio para que el video suene aunque el teléfono
  // esté en silencio (iOS) o el canal de audio esté en media (Android).
  useEffect(() => {
    if (!muted) {
      setAudioModeAsync({
        playsInSilentMode: true,
        shouldPlayInBackground: false,
      }).catch(() => {});
    }
  }, [muted]);

  const player = useVideoPlayer({ uri, useCaching: true }, (p) => {
    p.muted = muted;
    p.loop  = loop;
    if (startTime > 0) p.currentTime = startTime;
    if (autoPlay || posterFrame) p.play();
  });

  // El callback de useVideoPlayer (arriba) solo corre al crear el player —
  // si este componente se reutiliza con un `uri` distinto (ej. una lista
  // que se refresca y reordena filas), el player seguía mostrando la
  // fuente vieja. `player.replace(...)` fuerza la recarga real.
  const mountedUriRef = useRef(uri);
  useEffect(() => {
    setLoading(true);
    setHasError(false);

    if (mountedUriRef.current === uri) return;
    mountedUriRef.current = uri;

    try {
      player.replace({ uri, useCaching: true });
      player.muted = muted;
      player.loop  = loop;
      if (startTime > 0) player.currentTime = startTime;
      if (autoPlay || posterFrame) player.play();
    } catch {}
  }, [uri, player]);

  // Sincroniza mute cuando el prop cambia (botón silenciar / salir del explorador).
  // El callback de useVideoPlayer solo corre al iniciar, así que hace falta este effect.
  useEffect(() => {
    try { player.muted = muted; } catch {}
  }, [player, muted]);

  // Reproduce/pausa cuando el prop `autoPlay` cambia DESPUÉS del montaje
  // (ej. un carrusel donde el video activo cambia con el índice) — antes
  // solo se aplicaba una vez, al crear el player, así que el video de
  // atrás se seguía reproduciendo aunque ya no fuera el que se estaba viendo.
  const isFirstAutoPlaySync = useRef(true);
  useEffect(() => {
    if (isFirstAutoPlaySync.current) { isFirstAutoPlaySync.current = false; return; }
    try { autoPlay ? player.play() : player.pause(); } catch {}
  }, [player, autoPlay]);

  // Modo miniatura (tarjetas chicas del deck): sin esto expo-video a veces
  // nunca dibuja ningún cuadro si no se le pide reproducir — se queda en
  // negro o pegado en "cargando" aunque el archivo cargue bien. Arranca a
  // reproducir para forzar que decodifique el primer cuadro y lo pausa de
  // inmediato en cuanto el evento confirma que ya empezó.
  useEffect(() => {
    if (!posterFrame) return;
    const sub = player.addListener('playingChange', ({ isPlaying }) => {
      if (isPlaying) { try { player.pause(); } catch {} }
    });
    return () => sub.remove();
  }, [player, posterFrame]);

  useEffect(() => {
    const statusSub = player.addListener('statusChange', ({ status }) => {
      if (status === 'error') {
        console.warn('VideoPlayer: failed to load', uri);
        setHasError(true);
      }
      if (status !== 'loading') setLoading(false);
    });
    // Respaldo: si ya está reproduciendo de verdad, definitivamente no
    // sigue "cargando" — cierra el hueco de cuando statusChange no alcanza
    // a avisar (ej. se le dio play desde los controles nativos y el
    // listener se registró después de que el status ya había cambiado).
    const playingSub = player.addListener('playingChange', ({ isPlaying }) => {
      if (isPlaying) setLoading(false);
    });
    const endSub = player.addListener('playToEnd', () => {
      onEndRef.current?.();
    });
    return () => {
      statusSub.remove();
      playingSub.remove();
      endSub.remove();
    };
  }, [player]);

  return (
    <View style={[{ backgroundColor: '#000' }, style]}>
      <VideoView
        player={player}
        style={StyleSheet.absoluteFill}
        contentFit={contentFit}
        nativeControls={nativeControls}
      />
      {/* Con controles nativos, el propio reproductor del sistema ya
          muestra su indicador de carga/buffer — nuestro overlay encima
          solo tapaba esa UI y, por una carrera de eventos entre el JS y
          el player nativo, a veces se quedaba pegado aunque el video ya
          estuviera reproduciéndose. Sin controles nativos (tarjetas
          chicas, anuncios, etc.) sí hace falta, porque ahí no hay
          ninguna otra señal visual de carga. */}
      {loading && !hasError && !nativeControls && (
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
    ...StyleSheet.absoluteFill,
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.55)',
  },
  error: {
    ...StyleSheet.absoluteFill,
    alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.7)',
  },
  errorText: {
    color: '#ff5252',
    fontSize: 13,
  },
});
