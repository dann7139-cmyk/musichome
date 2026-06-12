import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Animated,
  AppState,
  Dimensions,
  Easing,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import MapView, { Marker } from 'react-native-maps';
import { LinearGradient } from 'expo-linear-gradient';
import * as Haptics from 'expo-haptics';
import { Clock, Users, Zap } from 'lucide-react-native';
import { COLORS, FONTS, RADIUS } from '../../config/theme';
import { EARTH_STYLE } from '../../constants/mapStyle';
import type { ExpressDispatch } from '../../context/ExpressContext';
import { useMotionPrefs } from '../../hooks/useMotionPrefs';
import { playCriticalTick } from '../../utils/expressSound';

// ── Public layout constants ───────────────────────────────────────────────────
const { width: W } = Dimensions.get('window');
export const CARD_WIDTH   = Math.round(W * 0.86);
export const LIST_PADDING = Math.round((W - CARD_WIDTH) / 2);
export const CARD_GAP     = 12;

// ── Map geometry (route particle path) ───────────────────────────────────────
const MAP_H      = 170;
const R_START_X  = CARD_WIDTH * 0.13;
const R_END_X    = CARD_WIDTH * 0.83;
const R_START_Y  = 100;
const R_END_Y    = 86;
const R_DX       = R_END_X - R_START_X;
const R_DY       = R_END_Y - R_START_Y;
const BASE_LEN   = Math.sqrt(R_DX * R_DX + R_DY * R_DY);
const BASE_ANGLE = Math.atan2(R_DY, R_DX) * 180 / Math.PI;
const BASE_CTR_X = (R_START_X + R_END_X) / 2;
const BASE_CTR_Y = (R_START_Y + R_END_Y) / 2;

const RING_CX = Math.round(R_END_X);
const RING_CY = Math.round(R_END_Y);
const RING_SZ = 168;

// Route path control points — shared by all particles
const P_T  = [0.00, 0.18, 0.38, 0.58, 0.76, 0.90, 1.00] as const;
const P_TX = P_T.map((_, i) => [R_START_X, CARD_WIDTH*0.27, CARD_WIDTH*0.44, CARD_WIDTH*0.59, CARD_WIDTH*0.72, CARD_WIDTH*0.80, R_END_X][i]);
const P_TY = [100, 91, 80, 76, 79, 85, R_END_Y] as const;

// ── City coords lookup ────────────────────────────────────────────────────────
const CITY_COORDS: Record<string, { lat: number; lng: number }> = {
  'ciudad de mexico': { lat: 19.4326, lng: -99.1332 },
  'cdmx':            { lat: 19.4326, lng: -99.1332 },
  'guadalajara':     { lat: 20.6597, lng: -103.3496 },
  'monterrey':       { lat: 25.6866, lng: -100.3161 },
  'puebla':          { lat: 19.0414, lng: -98.2063 },
  'tijuana':         { lat: 32.5149, lng: -117.0382 },
  'leon':            { lat: 21.1236, lng: -101.6858 },
  'queretaro':       { lat: 20.5888, lng: -100.3899 },
  'cancun':          { lat: 21.1619, lng: -86.8515 },
  'merida':          { lat: 20.9674, lng: -89.5926 },
  'hermosillo':      { lat: 29.0729, lng: -110.9559 },
  'chihuahua':       { lat: 28.6330, lng: -106.0691 },
  'veracruz':        { lat: 19.1739, lng: -96.1342 },
  'acapulco':        { lat: 16.8531, lng: -99.8237 },
  'san luis potosi': { lat: 22.1565, lng: -100.9855 },
  'aguascalientes':  { lat: 21.8818, lng: -102.2916 },
  'toluca':          { lat: 19.2826, lng: -99.6557 },
  'saltillo':        { lat: 25.4232, lng: -100.9963 },
  'morelia':         { lat: 19.7060, lng: -101.1950 },
  'default':         { lat: 19.4326, lng: -99.1332 },
};
function cityCoords(city: string) {
  const key = city.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
  return CITY_COORDS[key] ?? CITY_COORDS['default'];
}

// ── Dark map style — unificado en src/constants/mapStyle.ts ───────────────────
const MAP_STYLE = EARTH_STYLE;

const EVENT_LABELS: Record<string, string> = {
  fiesta_privada: 'Fiesta privada',
  boda:           'Boda',
  cumpleanos:     'Cumpleaños',
  graduacion:     'Graduación',
  empresarial:    'Empresarial',
  otro:           'Evento',
};

function fmtDate(d: string) {
  try { return new Date(d).toLocaleDateString('es-MX', { weekday: 'short', day: 'numeric', month: 'short' }); }
  catch { return d; }
}

// ── Ring — pulsing circle, native driver ──────────────────────────────────────
const Ring = React.memo(function Ring({ size, delay, color, isReduceMotion }: {
  size: number; delay: number; color: string; isReduceMotion: boolean;
}) {
  const scale   = useRef(new Animated.Value(0.5)).current;
  const opacity = useRef(new Animated.Value(0.7)).current;
  useEffect(() => {
    if (isReduceMotion) {
      scale.setValue(1.0);
      opacity.setValue(0.22);
      return;
    }
    const loop = Animated.loop(Animated.sequence([
      Animated.delay(delay),
      Animated.parallel([
        Animated.timing(scale,   { toValue: 1.55, duration: 2200, easing: Easing.out(Easing.ease), useNativeDriver: true }),
        Animated.timing(opacity, { toValue: 0,    duration: 2200, useNativeDriver: true }),
      ]),
      Animated.parallel([
        Animated.timing(scale,   { toValue: 0.5, duration: 0, useNativeDriver: true }),
        Animated.timing(opacity, { toValue: 0.7, duration: 0, useNativeDriver: true }),
      ]),
    ]));
    loop.start();
    return () => loop.stop();
  }, [delay, isReduceMotion]);
  return (
    <Animated.View pointerEvents="none" style={{
      position: 'absolute', width: size, height: size, borderRadius: size / 2,
      borderWidth: 1.5, borderColor: color, transform: [{ scale }], opacity,
    }} />
  );
});

// ── ArrivalRing — slingshot pulse synced to particle arrival ──────────────────
// No own loop — reads shared particleT, zero extra cost
const ArrivalRing = React.memo(function ArrivalRing({
  particleT, isReduceMotion,
}: { particleT: Animated.Value; isReduceMotion: boolean }) {
  const slingshotScale = particleT.interpolate({
    inputRange:  [0.0, 0.74, 0.80, 0.85, 0.91, 0.96, 1.0],
    outputRange: [0.7, 0.7,  0.62, 1.72, 0.82, 1.06, 0.7],
    extrapolate: 'clamp',
  });
  const normalOpacity = particleT.interpolate({
    inputRange:  [0.0, 0.77, 0.83, 0.94, 1.0],
    outputRange: [0.0, 0.0,  1.0,  0.0,  0.0],
    extrapolate: 'clamp',
  });
  // Reduce-motion: gentle blink only, no scale slingshot
  const reducedOpacity = particleT.interpolate({
    inputRange:  [0.0, 0.80, 0.88, 0.95, 1.0],
    outputRange: [0.0, 0.0,  0.32, 0.0,  0.0],
    extrapolate: 'clamp',
  });
  return (
    <Animated.View pointerEvents="none" style={{
      position: 'absolute', width: 42, height: 42, borderRadius: 21,
      borderWidth: 2, borderColor: COLORS.green,
      transform: isReduceMotion ? [] : [{ scale: slingshotScale }],
      opacity:   isReduceMotion ? reducedOpacity : normalOpacity,
    }} />
  );
});

// ── RouteFlow — drives particleT + renders base line + main + 3 trailing ──────
// isFocused: secondary trails + breath only render/animate on the centered card
function RouteFlow({ particleT, isFocused, isLowPower, isReduceMotion }: {
  particleT:      Animated.Value;
  isFocused:      boolean;
  isLowPower:     boolean;
  isReduceMotion: boolean;
}) {
  const mainLoopRef   = useRef<Animated.CompositeAnimation | null>(null);
  const breathLoopRef = useRef<Animated.CompositeAnimation | null>(null);
  const breathAnim    = useRef(new Animated.Value(0.35)).current;

  // ── Main loop — skipped entirely when reduce-motion is on ─────────────────
  useEffect(() => {
    if (isReduceMotion) {
      mainLoopRef.current?.stop();
      particleT.setValue(0);
      return;
    }

    particleT.setValue(0);
    const duration = isLowPower ? 4200 : 3000;
    const pause    = isLowPower ? 1000 : 700;

    const startMain = () => {
      const anim = Animated.loop(Animated.sequence([
        Animated.timing(particleT, {
          toValue: 1, duration,
          easing: Easing.bezier(0.35, 0.0, 0.65, 1.0),
          useNativeDriver: true,
        }),
        Animated.delay(pause),
        Animated.timing(particleT, { toValue: 0, duration: 0, useNativeDriver: true }),
        Animated.delay(200),
      ]));
      mainLoopRef.current = anim;
      anim.start();
    };

    startMain();

    const appSub = AppState.addEventListener('change', state => {
      if (state !== 'active') {
        mainLoopRef.current?.stop();
      } else {
        mainLoopRef.current?.stop();
        particleT.setValue(0);
        startMain();
      }
    });

    return () => {
      mainLoopRef.current?.stop();
      appSub.remove();
    };
  }, [particleT, isReduceMotion, isLowPower]);

  // ── Breathing base line — only when centered ───────────────────────────────
  useEffect(() => {
    breathLoopRef.current?.stop();
    if (!isFocused) {
      breathAnim.setValue(0.35);
      return;
    }
    const cycleDur = isLowPower ? 3000 : 2000;
    const anim = Animated.loop(Animated.sequence([
      Animated.timing(breathAnim, { toValue: 1.0,  duration: cycleDur, easing: Easing.sin, useNativeDriver: true }),
      Animated.timing(breathAnim, { toValue: 0.35, duration: cycleDur, easing: Easing.sin, useNativeDriver: true }),
    ]));
    breathLoopRef.current = anim;
    anim.start();
    return () => { breathLoopRef.current?.stop(); };
  }, [isFocused, breathAnim, isLowPower]);

  // ── Position interpolations ───────────────────────────────────────────────
  const mainTx = particleT.interpolate({ inputRange: [...P_T], outputRange: [...P_TX], extrapolate: 'clamp' });
  const mainTy = particleT.interpolate({ inputRange: [...P_T], outputRange: [...P_TY], extrapolate: 'clamp' });
  const mainSc = particleT.interpolate({
    inputRange:  [0.0, 0.12, 0.26, 0.40, 0.54, 0.68, 0.82, 0.93, 1.0],
    outputRange: [0.8, 1.28, 0.82, 1.22, 0.85, 1.18, 0.88, 1.12, 0.80],
    extrapolate: 'clamp',
  });
  const mainOp = particleT.interpolate({
    inputRange:  [0.0, 0.05, 0.88, 1.0],
    outputRange: [0,   1,    1,    0],
    extrapolate: 'clamp',
  });

  // Trail 1: closest, 0.10 phase behind
  const t1In = [0.10, 0.28, 0.48, 0.68, 0.86, 0.97, 1.00];
  const t1Tx = particleT.interpolate({ inputRange: t1In, outputRange: [...P_TX].slice(0, 7), extrapolate: 'clamp' });
  const t1Ty = particleT.interpolate({ inputRange: t1In, outputRange: [...P_TY].slice(0, 7) as number[], extrapolate: 'clamp' });
  const t1Op = particleT.interpolate({ inputRange: [0.10, 0.17, 0.88, 0.97], outputRange: [0, 0.48, 0.48, 0], extrapolate: 'clamp' });

  // Trail 2: mid, 0.20 phase behind
  const t2In = [0.20, 0.38, 0.58, 0.78, 0.95, 1.00];
  const t2Tx = particleT.interpolate({ inputRange: t2In, outputRange: [P_TX[0], P_TX[1], P_TX[2], P_TX[3], P_TX[4], P_TX[5]], extrapolate: 'clamp' });
  const t2Ty = particleT.interpolate({ inputRange: t2In, outputRange: [P_TY[0], P_TY[1], P_TY[2], P_TY[3], P_TY[4], P_TY[5]] as number[], extrapolate: 'clamp' });
  const t2Op = particleT.interpolate({ inputRange: [0.20, 0.27, 0.94, 1.00], outputRange: [0, 0.28, 0.28, 0], extrapolate: 'clamp' });

  // Trail 3: farthest, 0.30 phase behind
  const t3In = [0.30, 0.50, 0.70, 0.90, 1.00];
  const t3Tx = particleT.interpolate({ inputRange: t3In, outputRange: [P_TX[0], P_TX[1], P_TX[2], P_TX[3], P_TX[4]], extrapolate: 'clamp' });
  const t3Ty = particleT.interpolate({ inputRange: t3In, outputRange: [P_TY[0], P_TY[1], P_TY[2], P_TY[3], P_TY[4]] as number[], extrapolate: 'clamp' });
  const t3Op = particleT.interpolate({ inputRange: [0.30, 0.37, 0.89, 1.00], outputRange: [0, 0.16, 0.16, 0], extrapolate: 'clamp' });

  return (
    <View
      pointerEvents="none"
      style={StyleSheet.absoluteFill}
      renderToHardwareTextureAndroid={Platform.OS === 'android'}
    >
      {/* Base line — breathes when focused, dim static otherwise */}
      <Animated.View style={{
        position:        'absolute',
        left:            Math.round(BASE_CTR_X - BASE_LEN / 2),
        top:             Math.round(BASE_CTR_Y - 0.75),
        width:           Math.round(BASE_LEN),
        height:          1.5,
        backgroundColor: 'rgba(0,230,118,0.18)',
        borderRadius:    1,
        transform:       [{ rotate: `${BASE_ANGLE.toFixed(1)}deg` }],
        opacity:         breathAnim,
        shadowColor:    COLORS.green,
        shadowOffset:   { width: 0, height: 0 },
        shadowOpacity:  isLowPower ? 0.28 : 0.45,
        shadowRadius:   isLowPower ? 2 : 3,
        elevation:      2,
      }} />

      {/* Trails — centered card only, no particles in reduce-motion */}
      {isFocused && !isReduceMotion && (
        <>
          {/* t3 and t2 — skipped in low-power (1 trail only) */}
          {!isLowPower && (
            <>
              <Animated.View pointerEvents="none" style={{
                position: 'absolute', top: 0, left: 0,
                width: 2.5, height: 2.5, borderRadius: 1.25,
                backgroundColor: COLORS.green,
                transform: [{ translateX: t3Tx }, { translateY: t3Ty }],
                opacity: t3Op,
              }} />
              <Animated.View pointerEvents="none" style={{
                position: 'absolute', top: 0, left: 0,
                width: 3.5, height: 3.5, borderRadius: 1.75,
                backgroundColor: COLORS.green,
                transform: [{ translateX: t2Tx }, { translateY: t2Ty }],
                opacity: t2Op,
              }} />
            </>
          )}
          {/* t1 — always visible when focused */}
          <Animated.View pointerEvents="none" style={{
            position: 'absolute', top: 0, left: 0,
            width: 5, height: 5, borderRadius: 2.5,
            backgroundColor: COLORS.green,
            transform: [{ translateX: t1Tx }, { translateY: t1Ty }],
            opacity: t1Op,
          }} />
        </>
      )}

      {/* Main particle — hidden in reduce-motion */}
      {!isReduceMotion && (
        <Animated.View pointerEvents="none" style={{
          position:        'absolute',
          top: 0, left: 0,
          width: 7, height: 7, borderRadius: 3.5,
          backgroundColor: COLORS.green,
          shadowColor:     COLORS.green,
          shadowOffset:    { width: 0, height: 0 },
          shadowOpacity:   isLowPower ? 0.70 : 1,
          shadowRadius:    isLowPower ? 3 : 5,
          elevation:       isLowPower ? 3 : 5,
          transform:       [{ translateX: mainTx }, { translateY: mainTy }, { scale: mainSc }],
          opacity:         mainOp,
        }} />
      )}
    </View>
  );
}

// ── MapSection — memoized, owns particleT, never re-renders on countdown ──────
interface MapSectionProps {
  lat: number; lng: number;
  mLat: number; mLng: number;
  genre: string;
  isFocused: boolean;
  onTap: () => void;
}

const MapSection = React.memo(function MapSection({ lat, lng, mLat, mLng, genre, isFocused, onTap }: MapSectionProps) {
  const { isLowPower, isReduceMotion } = useMotionPrefs();
  const particleT = useRef(new Animated.Value(0)).current;

  // iOS: pitch + heading for depth; Android: liteMode (no GL on off-screen cards)
  const mapProps = Platform.OS === 'ios'
    ? {
        camera: {
          center:   { latitude: lat, longitude: lng },
          pitch:    28,
          heading:  20,
          altitude: 1600,
          zoom:     13,
        },
      }
    : {
        initialRegion: {
          latitude: lat, longitude: lng,
          latitudeDelta: 0.062, longitudeDelta: 0.062,
        },
        liteMode: true as true,
      };

  return (
    <View style={s.mapWrap}>
      <Pressable style={StyleSheet.absoluteFill} onPress={onTap} />

      <MapView
        style={StyleSheet.absoluteFill}
        customMapStyle={MAP_STYLE}
        scrollEnabled={false}
        zoomEnabled={false}
        rotateEnabled={false}
        pitchEnabled={false}
        pointerEvents="none"
        {...mapProps}
      >
        <Marker
          coordinate={{ latitude: mLat, longitude: mLng }}
          anchor={{ x: 0.5, y: 0.5 }}
          tracksViewChanges={false}
        >
          <View style={s.marker}>
            <View style={s.markerCore} />
          </View>
        </Marker>
      </MapView>

      {/* Rings near destination */}
      <View
        renderToHardwareTextureAndroid={Platform.OS === 'android'}
        pointerEvents="none"
        style={{
          position: 'absolute',
          left:   RING_CX - RING_SZ / 2,
          top:    Math.max(4, RING_CY - RING_SZ / 2),
          width:  RING_SZ, height: RING_SZ,
          alignItems: 'center', justifyContent: 'center',
        }}
      >
        <Ring size={56}  delay={0}    color="rgba(0,230,118,0.60)" isReduceMotion={isReduceMotion} />
        <Ring size={96}  delay={700}  color="rgba(0,230,118,0.32)" isReduceMotion={isReduceMotion} />
        <Ring size={140} delay={1400} color="rgba(0,230,118,0.15)" isReduceMotion={isReduceMotion} />
        <ArrivalRing particleT={particleT} isReduceMotion={isReduceMotion} />
      </View>

      {/* Route animation layer */}
      <RouteFlow particleT={particleT} isFocused={isFocused} isLowPower={isLowPower} isReduceMotion={isReduceMotion} />

      {/* Bottom gradient */}
      <LinearGradient
        colors={['transparent', 'rgba(6,12,6,0.68)', '#060c06']}
        style={s.mapGrad}
        pointerEvents="none"
      />

      {/* Genre chip */}
      <View style={s.genreChip} pointerEvents="none">
        <Zap size={9} color={COLORS.green} />
        <Text style={s.genreTx}>{genre}</Text>
      </View>
    </View>
  );
}, (prev, next) =>
  prev.lat      === next.lat      &&
  prev.lng      === next.lng      &&
  prev.genre    === next.genre    &&
  prev.isFocused === next.isFocused
);

// ── CountdownDisplay — isolated re-render island, ticks every second ──────────
function CountdownDisplay({ expiresAt }: { expiresAt?: string }) {
  const [ms, setMs] = useState(() =>
    expiresAt ? Math.max(0, new Date(expiresAt).getTime() - Date.now()) : 180_000
  );
  const criticalFiredRef = useRef(false);

  useEffect(() => {
    if (!expiresAt) return;
    const id = setInterval(() => setMs(Math.max(0, new Date(expiresAt).getTime() - Date.now())), 1_000);
    return () => clearInterval(id);
  }, [expiresAt]);

  const secs  = Math.ceil(ms / 1_000);

  useEffect(() => {
    if (secs <= 20 && secs > 0 && !criticalFiredRef.current) {
      criticalFiredRef.current = true;
      playCriticalTick();
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy).catch(() => {});
    }
  }, [secs]);

  const mins  = Math.floor(secs / 60);
  const sec   = secs % 60;
  const urgent = secs <= 20;
  const color = secs > 60 ? COLORS.green : secs > 20 ? '#FFA726' : COLORS.red;
  return (
    <View style={[s.cdChip, urgent && s.cdChipUrgent]}>
      <Clock size={9} color={color} />
      <Text style={[s.cdText, { color }]}>{`${mins}:${String(sec).padStart(2, '0')}`}</Text>
    </View>
  );
}

// ── ExpressCard ───────────────────────────────────────────────────────────────
interface Props {
  dispatch:   ExpressDispatch;
  onCotizar:  (id: string) => void;
  onDetails:  (id: string) => void;
  onDismiss:  (id: string) => void;
  isBlocked?: boolean;
  isFocused?: boolean; // true = centered in carousel, full animation
}

const ExpressCard = React.memo(function ExpressCard({
  dispatch, onCotizar, onDetails, onDismiss, isBlocked = false, isFocused = true,
}: Props) {
  const { id, request, status, expires_at } = dispatch;
  const isTaken = status === 'taken';

  // Entrance: spring from right on mount
  const entryX  = useRef(new Animated.Value(54)).current;
  const entryOp = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    Animated.parallel([
      Animated.spring(entryX,  { toValue: 0, tension: 80, friction: 10, useNativeDriver: true }),
      Animated.timing(entryOp, { toValue: 1, duration: 220, useNativeDriver: true }),
    ]).start();
  }, []);

  // Taken overlay fade-in
  const takenOp = useRef(new Animated.Value(0)).current;
  useEffect(() => {
    if (isTaken) Animated.timing(takenOp, { toValue: 1, duration: 250, useNativeDriver: true }).start();
  }, [isTaken]);

  const city      = request?.location_city ?? '';
  const { lat, lng } = cityCoords(city);
  const mLat      = lat + 0.0029;
  const mLng      = lng + 0.0022;
  const genre     = request?.genre ?? 'Express';

  const handleCotizar = useCallback(() => onCotizar(id), [id, onCotizar]);
  const handleDetails = useCallback(() => onDetails(id), [id, onDetails]);
  const handleDismiss = useCallback(() => onDismiss(id), [id, onDismiss]);

  return (
    <Animated.View style={{ transform: [{ translateX: entryX }], opacity: entryOp }}>
      <View style={s.card}>

        <MapSection lat={lat} lng={lng} mLat={mLat} mLng={mLng} genre={genre} isFocused={isFocused} onTap={handleDetails} />

        <View style={s.cdPosition} pointerEvents="none">
          <CountdownDisplay expiresAt={expires_at} />
        </View>

        <View style={s.body}>
          <Text style={s.eventType} numberOfLines={1}>
            {EVENT_LABELS[request?.event_type ?? ''] ?? 'Evento express'}
          </Text>
          <Text style={s.cityTx} numberOfLines={1}>
            {city}{request?.location_municipio ? `, ${request.location_municipio}` : ''}
          </Text>

          <View style={s.statsRow}>
            <View style={s.stat}>
              <Text style={s.statVal}>{request?.hours ?? '—'}</Text>
              <Text style={s.statLbl}>hrs</Text>
            </View>
            <View style={s.statDiv} />
            <View style={s.stat}>
              <Text style={s.statVal} numberOfLines={1}>
                {request?.event_date ? fmtDate(request.event_date) : '—'}
              </Text>
              <Text style={s.statLbl}>fecha</Text>
            </View>
            {request?.guest_count ? (
              <>
                <View style={s.statDiv} />
                <View style={s.stat}>
                  <View style={{ flexDirection: 'row', alignItems: 'center', gap: 3 }}>
                    <Users size={10} color={COLORS.muted2} />
                    <Text style={s.statVal}>{request.guest_count}</Text>
                  </View>
                  <Text style={s.statLbl}>personas</Text>
                </View>
              </>
            ) : null}
          </View>

          <View style={s.actions}>
            <Pressable onPress={handleDismiss} hitSlop={12}
              style={({ pressed }) => [s.btnGhost, pressed && { opacity: 0.5 }]}>
              <Text style={s.btnGhostTx}>Ignorar</Text>
            </Pressable>
            <Pressable onPress={handleDetails}
              style={({ pressed }) => [s.btnOutline, pressed && { opacity: 0.7 }]}>
              <Text style={s.btnOutlineTx}>Ver más</Text>
            </Pressable>
            <Pressable
              onPress={isBlocked ? undefined : handleCotizar}
              style={({ pressed }) => [
                s.btnPrimary,
                isBlocked && s.btnBlocked,
                !isBlocked && pressed && { opacity: 0.82 },
              ]}
            >
              <Zap size={12} color={isBlocked ? COLORS.muted : COLORS.bg} />
              <Text style={[s.btnPrimaryTx, isBlocked && { color: COLORS.muted }]}>
                {isBlocked ? 'En curso' : 'Cotizar'}
              </Text>
            </Pressable>
          </View>
        </View>

        {isBlocked && (
          <View style={s.blockedOverlay} pointerEvents="none">
            <Text style={s.blockedTx}>Cotización en progreso</Text>
            <Text style={s.blockedSub}>Termina la actual primero</Text>
          </View>
        )}

        {isTaken && (
          <Animated.View style={[StyleSheet.absoluteFill, s.takenOverlay, { opacity: takenOp }]} pointerEvents="none">
            <Text style={s.takenIcon}>⚡</Text>
            <Text style={s.takenTitle}>Otro grupo la tomó</Text>
            <Text style={s.takenSub}>Seguirán llegando más solicitudes</Text>
          </Animated.View>
        )}

      </View>
    </Animated.View>
  );
});

export default ExpressCard;

// ── Styles ────────────────────────────────────────────────────────────────────
const s = StyleSheet.create({
  card:     { width: CARD_WIDTH, backgroundColor: '#060c06', borderRadius: RADIUS.xl, overflow: 'hidden', borderWidth: 1, borderColor: 'rgba(0,230,118,0.14)' },
  mapWrap:  { height: MAP_H, overflow: 'hidden' },
  mapGrad:  { position: 'absolute', left: 0, right: 0, bottom: 0, height: 60 },
  marker:     { width: 18, height: 18, borderRadius: 9, backgroundColor: 'rgba(0,230,118,0.18)', borderWidth: 1.5, borderColor: COLORS.green, alignItems: 'center', justifyContent: 'center' },
  markerCore: { width: 7, height: 7, borderRadius: 3.5, backgroundColor: COLORS.green },

  genreChip: { position: 'absolute', top: 10, left: 10, flexDirection: 'row', alignItems: 'center', gap: 4, backgroundColor: 'rgba(0,0,0,0.72)', borderRadius: 20, paddingHorizontal: 8, paddingVertical: 4, borderWidth: 1, borderColor: 'rgba(0,230,118,0.28)' },
  genreTx:   { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.green, letterSpacing: 0.3, textTransform: 'capitalize' },

  cdPosition:    { position: 'absolute', top: MAP_H - 34, right: 10 },
  cdChip:        { flexDirection: 'row', alignItems: 'center', gap: 4, backgroundColor: 'rgba(0,0,0,0.72)', borderRadius: 20, paddingHorizontal: 8, paddingVertical: 4, borderWidth: 1, borderColor: 'rgba(255,255,255,0.1)' },
  cdChipUrgent:  { borderColor: 'rgba(239,83,80,0.5)', backgroundColor: 'rgba(239,83,80,0.1)' },
  cdText:        { fontFamily: FONTS.bodySemiBold, fontSize: 11, letterSpacing: 0.5 },

  body:      { paddingHorizontal: 16, paddingTop: 13, paddingBottom: 15, gap: 9 },
  eventType: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text, letterSpacing: 0.1 },
  cityTx:    { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: -5 },

  statsRow: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  stat:     { alignItems: 'flex-start', gap: 2 },
  statVal:  { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  statLbl:  { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted },
  statDiv:  { width: 1, height: 26, backgroundColor: 'rgba(255,255,255,0.07)' },

  actions:      { flexDirection: 'row', gap: 8, marginTop: 2 },
  btnGhost:     { paddingHorizontal: 12, paddingVertical: 10, borderRadius: RADIUS.lg, alignItems: 'center', justifyContent: 'center' },
  btnGhostTx:   { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted },
  btnOutline:   { flex: 1, paddingVertical: 10, borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(255,255,255,0.12)', alignItems: 'center', justifyContent: 'center' },
  btnOutlineTx: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  btnPrimary:   { flex: 1, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 5, paddingVertical: 10, borderRadius: RADIUS.lg, backgroundColor: COLORS.green },
  btnBlocked:   { backgroundColor: 'rgba(255,255,255,0.06)', borderWidth: 1, borderColor: 'rgba(255,255,255,0.08)' },
  btnPrimaryTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.bg },

  blockedOverlay: { position: 'absolute', bottom: 0, left: 0, right: 0, height: 56, backgroundColor: 'rgba(6,12,6,0.78)', alignItems: 'center', justifyContent: 'center', gap: 3 },
  blockedTx:      { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2 },
  blockedSub:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },

  takenOverlay: { backgroundColor: 'rgba(6,12,6,0.90)', alignItems: 'center', justifyContent: 'center', gap: 8, borderRadius: RADIUS.xl },
  takenIcon:    { fontSize: 32 },
  takenTitle:   { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  takenSub:     { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, textAlign: 'center', paddingHorizontal: 24 },
});
