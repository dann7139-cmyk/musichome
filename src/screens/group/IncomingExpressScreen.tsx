import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  Animated,
  Easing,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import MapView, { Circle, Marker, Polyline, PROVIDER_GOOGLE } from 'react-native-maps';
import * as Location from 'expo-location';
import * as Haptics from 'expo-haptics';
import { ArrowLeft, Calendar, Clock, MapPin, Music, Users, Zap } from 'lucide-react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { EARTH_STYLE } from '../../constants/mapStyle';
import { playQuotedSound, playTakenSound, playCriticalTick } from '../../utils/expressSound';

// ── Dark map style — unificado en src/constants/mapStyle.ts ───────────────────
const DARK_MAP_STYLE = EARTH_STYLE;

// ── City coords ───────────────────────────────────────────────────────────────
const CITY_COORDS: Record<string, { lat: number; lng: number }> = {
  'guadalajara':      { lat: 20.6597, lng: -103.3496 },
  'zapopan':          { lat: 20.7167, lng: -103.3833 },
  'tlaquepaque':      { lat: 20.6419, lng: -103.3117 },
  'tonalá':           { lat: 20.6236, lng: -103.2347 },
  'tonala':           { lat: 20.6236, lng: -103.2347 },
  'ciudad de méxico': { lat: 19.4326, lng: -99.1332 },
  'cdmx':             { lat: 19.4326, lng: -99.1332 },
  'monterrey':        { lat: 25.6866, lng: -100.3161 },
  'puebla':           { lat: 19.0414, lng: -98.2063 },
  'tijuana':          { lat: 32.5149, lng: -117.0382 },
  'león':             { lat: 21.1221, lng: -101.6826 },
  'leon':             { lat: 21.1221, lng: -101.6826 },
  'aguascalientes':   { lat: 21.8818, lng: -102.2916 },
  'querétaro':        { lat: 20.5888, lng: -100.3899 },
  'queretaro':        { lat: 20.5888, lng: -100.3899 },
  'mérida':           { lat: 20.9674, lng: -89.5926 },
  'merida':           { lat: 20.9674, lng: -89.5926 },
  'cancún':           { lat: 21.1619, lng: -86.8515 },
  'cancun':           { lat: 21.1619, lng: -86.8515 },
  'veracruz':         { lat: 19.1738, lng: -96.1342 },
  'puerto vallarta':  { lat: 20.6534, lng: -105.2253 },
  'culiacán':         { lat: 24.8091, lng: -107.3940 },
  'culiacan':         { lat: 24.8091, lng: -107.3940 },
  'hermosillo':       { lat: 29.0729, lng: -110.9559 },
  'chihuahua':        { lat: 28.6330, lng: -106.0691 },
  'oaxaca':           { lat: 17.0732, lng: -96.7266 },
  'morelia':          { lat: 19.7060, lng: -101.1950 },
  'saltillo':         { lat: 25.4270, lng: -101.0034 },
  'durango':          { lat: 24.0277, lng: -104.6532 },
  'mazatlán':         { lat: 23.2494, lng: -106.4111 },
  'mazatlan':         { lat: 23.2494, lng: -106.4111 },
};

function idHash(id: string): number {
  let h = 5381;
  for (let i = 0; i < id.length; i++) h = ((h << 5) + h + id.charCodeAt(i)) | 0;
  return Math.abs(h);
}

// Returns event destination with a small privacy offset so the group sees
// approximately where the event is without revealing the exact address.
// Priority: (1) address pin from map picker → (2) client GPS at creation time
//           → (3) city-name dictionary lookup (last resort, least accurate).
function privacyOffset(
  id:         string,
  city:       string,
  municipio?: string | null,
  lat?:       number | null,   // event_requests.latitude  (map picker)
  lng?:       number | null,   // event_requests.longitude (map picker)
  eventLat?:  number | null,   // event_requests.event_lat (client GPS)
  eventLng?:  number | null,   // event_requests.event_lng (client GPS)
) {
  const h    = idHash(id);
  const dlat = ((h % 800) - 400) / 50_000;   // ±~890 m
  const dlng = (((h * 31) % 800) - 400) / 50_000;

  // 1. Event address from map picker — most accurate
  if (lat != null && lng != null) {
    return { latitude: lat + dlat, longitude: lng + dlng };
  }

  // 2. Client's GPS position when creating the request — reasonably close
  if (eventLat != null && eventLng != null) {
    return { latitude: eventLat + dlat, longitude: eventLng + dlng };
  }

  // 3. Last resort: city-name lookup dictionary
  const key  = (municipio ?? city).toLowerCase().trim();
  const base =
    CITY_COORDS[key] ??
    Object.entries(CITY_COORDS).find(([k]) => key.includes(k) || k.includes(key))?.[1] ??
    { lat: 20.6597, lng: -103.3496 };
  return { latitude: base.lat + dlat, longitude: base.lng + dlng };
}

function buildRoute(
  origin: { latitude: number; longitude: number },
  dest:   { latitude: number; longitude: number }
) {
  const pts = [];
  for (let i = 0; i <= 8; i++) {
    const t    = i / 8;
    const lat  = origin.latitude  + (dest.latitude  - origin.latitude)  * t;
    const lng  = origin.longitude + (dest.longitude - origin.longitude) * t;
    const curve = Math.sin(t * Math.PI) * 0.0025;
    pts.push({ latitude: lat - (dest.longitude - origin.longitude) * curve,
               longitude: lng + (dest.latitude  - origin.latitude)  * curve });
  }
  return pts;
}

function lerpRoute(route: { latitude: number; longitude: number }[], t: number) {
  const clamped = Math.max(0, Math.min(1, t));
  const idx = clamped * (route.length - 1);
  const lo  = Math.floor(idx);
  const hi  = Math.min(route.length - 1, lo + 1);
  const frac = idx - lo;
  return {
    latitude:  route[lo].latitude  + (route[hi].latitude  - route[lo].latitude)  * frac,
    longitude: route[lo].longitude + (route[hi].longitude - route[lo].longitude) * frac,
  };
}

const EVENT_LABELS: Record<string, string> = {
  fiesta_privada: '🎉 Fiesta privada',
  boda:           '💍 Boda',
  cumpleanos:     '🎂 Cumpleaños',
  graduacion:     '🎓 Graduación',
  empresarial:    '🏢 Empresarial',
  otro:           '🎵 Evento',
};

function formatDate(d: string) {
  return new Date(d + 'T12:00:00').toLocaleDateString('es-MX', {
    weekday: 'long', day: 'numeric', month: 'long',
  });
}

function formatCountdown(ms: number) {
  if (ms <= 0) return '0:00';
  const m = Math.floor(ms / 60_000);
  const s = Math.floor((ms % 60_000) / 1_000);
  return `${m}:${String(s).padStart(2, '0')}`;
}

// Countdown color thresholds
function cdColor(ms: number): string {
  if (ms > 30_000) return COLORS.green;
  if (ms > 10_000) return COLORS.gold;
  if (ms > 5_000)  return COLORS.orange;
  return COLORS.red;
}
function cdBg(ms: number): string {
  if (ms > 30_000) return 'rgba(0,230,118,0.07)';
  if (ms > 10_000) return 'rgba(255,179,0,0.10)';
  if (ms > 5_000)  return 'rgba(255,152,0,0.12)';
  return 'rgba(239,83,80,0.13)';
}
function cdBorder(ms: number): string {
  if (ms > 30_000) return 'rgba(0,230,118,0.2)';
  if (ms > 10_000) return 'rgba(255,179,0,0.35)';
  if (ms > 5_000)  return 'rgba(255,152,0,0.45)';
  return 'rgba(239,83,80,0.55)';
}
// Threshold bands for haptic triggers
function cdBand(ms: number): number {
  if (ms > 30_000) return 3;
  if (ms > 10_000) return 2;
  if (ms > 5_000)  return 1;
  return 0;
}

// ── ExpressLoader ─────────────────────────────────────────────────────────────
function ExpressLoader() {
  const bars = useRef(
    Array.from({ length: 5 }, (_, i) => new Animated.Value(i % 2 === 0 ? 0.4 : 0.2))
  ).current;
  const glowOpacity = useRef(new Animated.Value(0.35)).current;

  useEffect(() => {
    bars.forEach((bar, i) => {
      Animated.loop(
        Animated.sequence([
          Animated.delay(i * 110),
          Animated.timing(bar, { toValue: 1.0, duration: 400 + i * 25, useNativeDriver: false }),
          Animated.timing(bar, { toValue: 0.15, duration: 400 + i * 25, useNativeDriver: false }),
        ])
      ).start();
    });
    Animated.loop(
      Animated.sequence([
        Animated.timing(glowOpacity, { toValue: 0.85, duration: 900, useNativeDriver: true }),
        Animated.timing(glowOpacity, { toValue: 0.3,  duration: 900, useNativeDriver: true }),
      ])
    ).start();
  }, []);

  return (
    <View style={sl.root}>
      <Animated.View style={[sl.glowRing, { opacity: glowOpacity }]} />
      <View style={sl.equalizerRow}>
        {bars.map((bar, i) => (
          <View key={i} style={sl.barWrapper}>
            <Animated.View style={[sl.bar, {
              height:  bar.interpolate({ inputRange: [0, 1], outputRange: [6, 48] }),
              opacity: bar.interpolate({ inputRange: [0.15, 1], outputRange: [0.3, 1] }),
            }]} />
          </View>
        ))}
      </View>
      <View style={sl.badge}>
        <Zap size={11} color={COLORS.green} />
        <Text style={sl.badgeText}>SOLICITUD EXPRESS</Text>
      </View>
      <Text style={sl.hint}>Buscando información del evento…</Text>
    </View>
  );
}

const sl = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg, alignItems: 'center', justifyContent: 'center', gap: 28 },
  glowRing: {
    position: 'absolute',
    width: 160, height: 160, borderRadius: 80,
    borderWidth: 1, borderColor: COLORS.green,
    shadowColor: COLORS.green, shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.55, shadowRadius: 22, elevation: 0,
  },
  equalizerRow: { flexDirection: 'row', alignItems: 'flex-end', gap: 5, height: 56 },
  barWrapper:   { width: 8, height: 56, justifyContent: 'flex-end' },
  bar: {
    width: 8, borderRadius: 4, backgroundColor: COLORS.green,
    shadowColor: COLORS.green, shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.7, shadowRadius: 5, elevation: 3,
  },
  badge: {
    flexDirection: 'row', alignItems: 'center', gap: 6,
    backgroundColor: 'rgba(0,230,118,0.10)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.28)',
    borderRadius: RADIUS.full, paddingHorizontal: 14, paddingVertical: 7,
  },
  badgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green, letterSpacing: 1 },
  hint:      { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
});

// ── DestinationMarker ─────────────────────────────────────────────────────────
function DestinationMarker() {
  const ring1       = useRef(new Animated.Value(1)).current;
  const ring2       = useRef(new Animated.Value(0.6)).current;
  const ring3       = useRef(new Animated.Value(0.3)).current;
  const glowScale   = useRef(new Animated.Value(1)).current;
  const glowOpacity = useRef(new Animated.Value(0.08)).current;

  useEffect(() => {
    const pulse = (val: Animated.Value, dur: number, delay: number) =>
      Animated.loop(
        Animated.sequence([
          Animated.delay(delay),
          Animated.timing(val, { toValue: 1.9, duration: dur, easing: Easing.out(Easing.ease), useNativeDriver: true }),
          Animated.timing(val, { toValue: 1,   duration: dur, easing: Easing.in(Easing.ease),  useNativeDriver: true }),
        ])
      ).start();
    pulse(ring1, 1400, 0);
    pulse(ring2, 1400, 350);
    pulse(ring3, 1400, 700);

    // Glow base — slow breath behind the rings
    Animated.loop(
      Animated.sequence([
        Animated.parallel([
          Animated.timing(glowScale,   { toValue: 1.3,  duration: 2000, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
          Animated.timing(glowOpacity, { toValue: 0.20, duration: 2000, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
        ]),
        Animated.parallel([
          Animated.timing(glowScale,   { toValue: 0.85, duration: 2000, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
          Animated.timing(glowOpacity, { toValue: 0.05, duration: 2000, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
        ]),
      ])
    ).start();
  }, []);

  return (
    <View style={{ width: 140, height: 140, alignItems: 'center', justifyContent: 'center' }}>
      <Animated.View style={[s.glowBase, { opacity: glowOpacity, transform: [{ scale: glowScale }] }]} />
      <Animated.View style={[s.pulse, { width: 80, height: 80, borderRadius: 40, opacity: 0.12, transform: [{ scale: ring1 }] }]} />
      <Animated.View style={[s.pulse, { width: 52, height: 52, borderRadius: 26, opacity: 0.25, transform: [{ scale: ring2 }] }]} />
      <Animated.View style={[s.pulse, { width: 28, height: 28, borderRadius: 14, opacity: 0.45, transform: [{ scale: ring3 }] }]} />
      <View style={s.pulseCenter} />
    </View>
  );
}

// ── RouteParticle (throttled to ~4fps) ────────────────────────────────────────
function RouteParticle({ route, delay }: { route: { latitude: number; longitude: number }[]; delay: number }) {
  const [pos, setPos] = useState(lerpRoute(route, 0));

  useEffect(() => {
    if (route.length < 2) return;
    let startTime: number | null = null;
    const DURATION = 3500;
    const THROTTLE = 250;
    let lastUpdate = 0;
    let frameId: number;
    const delayEnd = Date.now() + delay;

    const tick = (now: number) => {
      frameId = requestAnimationFrame(tick);
      if (now < delayEnd) return;
      if (startTime === null) startTime = now;
      if (now - lastUpdate < THROTTLE) return;
      lastUpdate = now;
      setPos(lerpRoute(route, ((now - startTime) % DURATION) / DURATION));
    };

    frameId = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frameId);
  }, [route, delay]);

  return (
    <Marker coordinate={pos} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}>
      <View style={s.particle} />
    </Marker>
  );
}

// ── InfoRow ───────────────────────────────────────────────────────────────────
function InfoRow({ icon, text }: { icon: React.ReactNode; text: string }) {
  return (
    <View style={s.infoRow}>
      {icon}
      <Text style={s.infoText}>{text}</Text>
    </View>
  );
}

// ── Main screen ───────────────────────────────────────────────────────────────
export default function IncomingExpressScreen({ route, navigation }: any) {
  const { dispatchId } = route.params as { dispatchId: string };

  const [request,        setRequest]        = useState<any>(null);
  const [loading,        setLoading]        = useState(true);
  const [lockState,      setLockState]      = useState<'idle' | 'locking' | 'locked' | 'error'>('idle');
  const [lockExpires,    setLockExpires]    = useState<Date | null>(null);
  const [countdown,      setCountdown]      = useState('');
  const [countdownMs,    setCountdownMs]    = useState(120_000);
  const [origin,         setOrigin]         = useState<{ latitude: number; longitude: number } | null>(null);
  const [dest,           setDest]           = useState<{ latitude: number; longitude: number } | null>(null);
  const [routePts,       setRoutePts]       = useState<{ latitude: number; longitude: number }[]>([]);
  const [takenVisible,   setTakenVisible]   = useState(false);
  const [takenCount,     setTakenCount]     = useState<number | null>(null);
  const [quotedVisible,  setQuotedVisible]  = useState(false);
  const [rippleVisible,  setRippleVisible]  = useState(false);

  // ── Animated values ───────────────────────────────────────────────────────
  const sheetY          = useRef(new Animated.Value(400)).current;
  const topFade         = useRef(new Animated.Value(0)).current;
  const mapOverlay      = useRef(new Animated.Value(0)).current;
  const rippleAnim      = useRef(new Animated.Value(0)).current;
  const checkScale      = useRef(new Animated.Value(0)).current;
  const cdShake         = useRef(new Animated.Value(0)).current;
  const cdValueScale    = useRef(new Animated.Value(1)).current;
  const mountScale      = useRef(new Animated.Value(0.97)).current;
  // Per-element stagger: [label, infoGrid, countdown, btnPrimary, btnSecondary]
  const itemFade        = useRef(Array.from({ length: 5 }, () => new Animated.Value(0))).current;

  // Spatial expansion from mini-map: 0.97 → 1.0 on mount
  useEffect(() => {
    Animated.timing(mountScale, {
      toValue: 1.0, duration: 280,
      easing: Easing.out(Easing.ease),
      useNativeDriver: true,
    }).start();
  }, []);

  // ── Refs ──────────────────────────────────────────────────────────────────
  const heartbeatRef    = useRef<ReturnType<typeof setInterval> | null>(null);
  const countdownRef    = useRef<ReturnType<typeof setInterval> | null>(null);
  const autoBackRef     = useRef<ReturnType<typeof setTimeout>  | null>(null);
  const mapRef          = useRef<MapView>(null);
  const mountedRef      = useRef(true);
  const bandRef         = useRef(-1);         // countdown band for threshold haptics
  const quotedDoneRef   = useRef(false);      // prevents double-trigger from params + Realtime

  // ── Stagger entrance helper ───────────────────────────────────────────────
  const runStagger = useCallback((direction: 'in' | 'out') => {
    const target = direction === 'in' ? 1 : 0;
    const anims  = direction === 'out' ? [...itemFade].reverse() : itemFade;
    Animated.stagger(55, anims.map(fade =>
      Animated.timing(fade, {
        toValue: target,
        duration: 260,
        easing: direction === 'in' ? Easing.out(Easing.back(1.15)) : Easing.in(Easing.ease),
        useNativeDriver: true,
      })
    )).start();
  }, [itemFade]);

  // ── Shake helper for critical countdown ──────────────────────────────────
  const shakeCountdown = useCallback(() => {
    Animated.sequence([
      Animated.timing(cdShake, { toValue: -5, duration: 50, useNativeDriver: true }),
      Animated.timing(cdShake, { toValue:  5, duration: 50, useNativeDriver: true }),
      Animated.timing(cdShake, { toValue: -3, duration: 40, useNativeDriver: true }),
      Animated.timing(cdShake, { toValue:  0, duration: 40, useNativeDriver: true }),
    ]).start();
  }, [cdShake]);

  // ── Taken handler ─────────────────────────────────────────────────────────
  const handleTaken = useCallback(() => {
    if (!mountedRef.current) return;
    playTakenSound();
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Heavy).catch(() => {});

    if (heartbeatRef.current) { clearInterval(heartbeatRef.current); heartbeatRef.current = null; }
    if (countdownRef.current) { clearInterval(countdownRef.current); countdownRef.current = null; }

    // Darken map
    Animated.timing(mapOverlay, { toValue: 0.78, duration: 500, useNativeDriver: true }).start();

    // Fade out sheet items reverse-stagger, then show taken content
    runStagger('out');
    setTimeout(() => {
      if (!mountedRef.current) return;
      setTakenVisible(true);
    }, 350);

    // Fetch how many groups received this request (non-blocking)
    if (request?.id) {
      supabase
        .from('express_dispatches')
        .select('id', { count: 'exact', head: true })
        .eq('request_id', request.id)
        .then(({ count: c }) => {
          if (mountedRef.current) setTakenCount(c ?? null);
        });
    }
  }, [request, mapOverlay, runStagger]);

  // ── Quoted handler ────────────────────────────────────────────────────────
  const handleQuoted = useCallback(() => {
    if (!mountedRef.current || quotedDoneRef.current) return;
    quotedDoneRef.current = true;
    playQuotedSound();

    // Haptic sequence: three hits
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => {});
    setTimeout(() => Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => {}), 80);
    setTimeout(() => Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {}), 180);

    if (heartbeatRef.current) { clearInterval(heartbeatRef.current); heartbeatRef.current = null; }
    if (countdownRef.current) { clearInterval(countdownRef.current); countdownRef.current = null; }

    // Green ripple from center
    setRippleVisible(true);
    rippleAnim.setValue(0);
    Animated.timing(rippleAnim, {
      toValue: 1, duration: 800, easing: Easing.out(Easing.cubic), useNativeDriver: true,
    }).start(() => { if (mountedRef.current) setRippleVisible(false); });

    // Fade out items, show success
    runStagger('out');
    setTimeout(() => {
      if (!mountedRef.current) return;
      setQuotedVisible(true);
      Animated.spring(checkScale, { toValue: 1, tension: 70, friction: 7, useNativeDriver: true }).start();
    }, 350);
  }, [rippleAnim, checkScale, runStagger]);

  // ── quotedSuccess param — fired by ProposeRequestScreen on success ────────
  useEffect(() => {
    if (route.params?.quotedSuccess) handleQuoted();
  }, [route.params?.quotedSuccess]);

  // ── Data load + Realtime ──────────────────────────────────────────────────
  useEffect(() => {
    mountedRef.current = true;

    const channel = supabase
      .channel(`incoming_express_screen:${dispatchId}`)
      .on('postgres_changes' as any, {
        event: 'UPDATE', schema: 'public',
        table: 'express_dispatches', filter: `id=eq.${dispatchId}`,
      }, (payload: any) => {
        if (!mountedRef.current) return;
        const { status } = payload.new;
        if (status === 'quoted') {
          handleQuoted();
        } else if (status === 'taken') {
          handleTaken();
        }
      })
      .subscribe();

    (async () => {
      const timeout = new Promise<null>(r => setTimeout(() => r(null), 8_000));

      const { data: d } = await Promise.race([
        supabase.from('express_dispatches')
          .select('id,request_id,status,group_id')
          .eq('id', dispatchId).single(),
        timeout.then(() => ({ data: null, error: null })),
      ]) as any;

      if (!mountedRef.current) return;
      if (!d) { navigation.goBack(); return; }

      const { data: r } = await Promise.race([
        supabase.from('event_requests')
          .select('id,event_type,genre,event_date,event_time,hours,guest_count,location_city,location_municipio,location_estado,latitude,longitude,event_lat,event_lng,venue_covered,needs_sound,comments')
          .eq('id', d.request_id).single(),
        timeout.then(() => ({ data: null, error: null })),
      ]) as any;

      if (!mountedRef.current) return;
      setRequest(r);

      // Mark viewed (fire-and-forget)
      supabase.rpc('view_express_dispatch', { p_dispatch_id: dispatchId });

      // Show map immediately with fallback origin — GPS refines in background
      const privDest = r ? privacyOffset(r.id, r.location_city, r.location_municipio, r.latitude, r.longitude, r.event_lat, r.event_lng) : null;
      const fallbackOrigin = privDest
        ? { latitude: privDest.latitude + 0.015, longitude: privDest.longitude + 0.01 }
        : null;

      if (privDest && fallbackOrigin) {
        setDest(privDest);
        setOrigin(fallbackOrigin);
        setRoutePts(buildRoute(fallbackOrigin, privDest));
      }

      setLoading(false);

      // Entrance animations: sheet spring + top fade
      Animated.parallel([
        Animated.spring(sheetY,  { toValue: 0, tension: 55, friction: 10, useNativeDriver: true }),
        Animated.timing(topFade, { toValue: 1, duration: 600, useNativeDriver: true }),
      ]).start();

      if (fallbackOrigin && privDest) {
        setTimeout(() => {
          mapRef.current?.fitToCoordinates([fallbackOrigin, privDest], {
            edgePadding: { top: 120, right: 50, bottom: 420, left: 50 }, animated: true,
          });
        }, 900);
      }

      // Stagger sheet elements after sheet slides up
      setTimeout(() => { if (mountedRef.current) runStagger('in'); }, 300);

      // GPS in background — refines origin marker and route when available
      if (privDest) {
        void (async () => {
          try {
            const { status } = await Location.requestForegroundPermissionsAsync();
            if (status !== 'granted') return;
            const loc = await Promise.race([
              Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced }),
              new Promise<null>(resolve => setTimeout(() => resolve(null), 3_000)),
            ]);
            if (!mountedRef.current) return;
            if (loc && 'coords' in loc) {
              const gpsOrigin = { latitude: loc.coords.latitude, longitude: loc.coords.longitude };
              setOrigin(gpsOrigin);
              setRoutePts(buildRoute(gpsOrigin, privDest));
              mapRef.current?.fitToCoordinates([gpsOrigin, privDest], {
                edgePadding: { top: 120, right: 50, bottom: 420, left: 50 }, animated: true,
              });
            }
          } catch {}
        })();
      }
    })();

    return () => {
      mountedRef.current = false;
      supabase.removeChannel(channel);
      if (heartbeatRef.current) clearInterval(heartbeatRef.current);
      if (countdownRef.current) clearInterval(countdownRef.current);
      if (autoBackRef.current)  clearTimeout(autoBackRef.current);
    };
  }, [dispatchId]);

  // ── Countdown tick ────────────────────────────────────────────────────────
  useEffect(() => {
    if (!lockExpires) return;
    bandRef.current = -1;

    const tick = () => {
      const remaining = lockExpires.getTime() - Date.now();

      if (remaining <= 0) {
        setCountdown('0:00');
        setCountdownMs(0);
        setLockState('idle');
        setLockExpires(null);
        clearInterval(countdownRef.current!);
        clearInterval(heartbeatRef.current!);
        return;
      }

      setCountdown(formatCountdown(remaining));
      setCountdownMs(remaining);

      const band = cdBand(remaining);
      if (band !== bandRef.current) {
        bandRef.current = band;
        if (band === 2) Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light).catch(() => {});
        if (band === 1) Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => {});
        if (band === 0) {
          // micro-bounce when first entering critical
          Animated.sequence([
            Animated.timing(cdValueScale, { toValue: 1.12, duration: 110, useNativeDriver: true }),
            Animated.timing(cdValueScale, { toValue: 1.0,  duration: 110, useNativeDriver: true }),
          ]).start();
        }
      }

      // Per-second haptic + shake + tick sound in critical zone
      if (band === 0 && remaining > 0) {
        playCriticalTick();
        shakeCountdown();
        Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning).catch(() => {});
      }

      // Bounce on each second in warning zone (band ≤ 1)
      if (band <= 1) {
        Animated.sequence([
          Animated.timing(cdValueScale, { toValue: 1.08, duration: 90, useNativeDriver: true }),
          Animated.timing(cdValueScale, { toValue: 1.0,  duration: 90, useNativeDriver: true }),
        ]).start();
      }
    };

    tick();
    countdownRef.current = setInterval(tick, 1_000);
    return () => clearInterval(countdownRef.current!);
  }, [lockExpires]);

  // ── Cotizar ───────────────────────────────────────────────────────────────
  const handleCotizar = async () => {
    if (lockState === 'locking') return;
    setLockState('locking');
    try { await Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium); } catch {}

    const { data, error } = await supabase.rpc('lock_express_dispatch', { p_dispatch_id: dispatchId });

    if (error || !data?.ok) {
      const reason = data?.error ?? 'unknown';
      if (reason === 'already_taken' || reason === 'locked_by_other') {
        handleTaken();
      } else {
        setLockState('idle');
      }
      return;
    }

    setLockExpires(new Date(data.lock_expires_at));
    setLockState('locked');

    heartbeatRef.current = setInterval(async () => {
      await supabase.rpc('heartbeat_express_lock', { p_dispatch_id: dispatchId });
    }, 30_000);

    navigation.navigate('ProposeRequest', { request, dispatchId });
  };

  const handleIgnorar = async () => {
    await supabase.rpc('ignore_express_dispatch', { p_dispatch_id: dispatchId });
    navigation.goBack();
  };

  // ── Render: loader ────────────────────────────────────────────────────────
  if (loading || !dest) return <ExpressLoader />;

  const region = {
    latitude: dest.latitude, longitude: dest.longitude,
    latitudeDelta: 0.045,    longitudeDelta: 0.045,
  };

  const curColor  = cdColor(countdownMs);
  const curBg     = cdBg(countdownMs);
  const curBorder = cdBorder(countdownMs);

  return (
    <Animated.View style={[s.root, { transform: [{ scale: mountScale }] }]}>
      {/* ── Map ── */}
      <MapView
        ref={mapRef}
        style={StyleSheet.absoluteFillObject}
        provider={PROVIDER_GOOGLE}
        customMapStyle={DARK_MAP_STYLE}
        initialRegion={region}
        scrollEnabled={true} zoomEnabled={true} rotateEnabled={false}
        pitchEnabled={false}  showsUserLocation={false}
        showsCompass={false}  showsMyLocationButton={false}
        onMapReady={() => {
          mapRef.current?.fitToCoordinates(
            [origin ?? { latitude: dest.latitude + 0.015, longitude: dest.longitude + 0.01 }, dest],
            { edgePadding: { top: 120, right: 50, bottom: 420, left: 50 }, animated: false },
          );
        }}
      >
        <Circle center={dest} radius={900}
          fillColor="rgba(0,230,118,0.05)" strokeColor="rgba(0,230,118,0.28)" strokeWidth={1.5} />

        {routePts.length > 1 && (
          <Polyline coordinates={routePts} strokeWidth={12} strokeColor="rgba(255,255,255,0.10)" />
        )}
        {routePts.length > 1 && (
          <Polyline
            coordinates={routePts}
            strokeWidth={3}
            strokeColor="rgba(255,255,255,0.70)"
            {...(Platform.OS === 'ios' ? { lineDashPattern: [8, 5] } : {})}
          />
        )}

        {/* Particles only when map is active */}
        {routePts.length > 1 && !takenVisible && !quotedVisible && (
          <>
            <RouteParticle route={routePts} delay={0} />
            <RouteParticle route={routePts} delay={1200} />
          </>
        )}

        {origin && (
          <Marker coordinate={origin} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}>
            <View style={s.originDot}><View style={s.originInner} /></View>
          </Marker>
        )}
      </MapView>

      {/* Dark overlay for taken/quoted states */}
      <Animated.View
        pointerEvents="none"
        style={[StyleSheet.absoluteFillObject, { backgroundColor: '#000', opacity: mapOverlay }]}
      />

      {/* Green ripple for quoted success */}
      {rippleVisible && (
        <Animated.View
          pointerEvents="none"
          style={[s.ripple, {
            opacity:   rippleAnim.interpolate({ inputRange: [0, 0.45, 1], outputRange: [0.22, 0.07, 0] }),
            transform: [{ scale: rippleAnim.interpolate({ inputRange: [0, 1], outputRange: [0.2, 5.5] }) }],
          }]}
        />
      )}

      {/* ── Gradients ── */}
      <LinearGradient colors={['rgba(4,4,4,0.85)', 'rgba(4,4,4,0)']}
        style={s.topGrad} pointerEvents="none" />
      <LinearGradient colors={['rgba(4,4,4,0)', 'rgba(4,4,4,0.97)']}
        style={s.bottomGrad} pointerEvents="none" />

      {/* ── Top bar ── */}
      <View style={s.topBar}>
        <SafeAreaView edges={['top']}>
          <View style={s.topRow}>
            <Pressable style={s.backBtn} onPress={handleIgnorar}>
              <ArrowLeft size={20} color={COLORS.text} />
            </Pressable>
            <View style={s.expressBadge}>
              <Zap size={12} color={COLORS.green} style={{ marginRight: 5 }} />
              <Text style={s.expressBadgeText}>SOLICITUD EXPRESS</Text>
              <View style={s.badgeDot} />
            </View>
            <View style={{ width: 40 }} />
          </View>
        </SafeAreaView>
      </View>

      {/* ── Bottom sheet ── */}
      <Animated.View style={[s.sheet, { transform: [{ translateY: sheetY }] }]}>
        <View style={s.handle} />

        {/* ── TAKEN STATE ── */}
        {takenVisible ? (
          <TakenContent groupCount={takenCount} onContinue={() => navigation.goBack()} />
        ) : quotedVisible ? (
          /* ── QUOTED SUCCESS STATE ── */
          <QuotedContent checkScale={checkScale} />
        ) : (
          /* ── NORMAL STATE ── */
          <>
            {/* Event label */}
            <Animated.View style={{ opacity: itemFade[0] }}>
              <Text style={s.eventLabel}>{EVENT_LABELS[request?.event_type] ?? '🎵 Evento express'}</Text>
            </Animated.View>

            {/* Info grid */}
            <Animated.View style={[s.infoGrid, { opacity: itemFade[1] }]}>
              {request?.event_date   && <InfoRow icon={<Calendar size={14} color={COLORS.green} />} text={formatDate(request.event_date)} />}
              {request?.hours        && <InfoRow icon={<Clock    size={14} color={COLORS.green} />} text={`${request.hours} ${request.hours === 1 ? 'hora' : 'horas'}`} />}
              {request?.location_city && <InfoRow icon={<MapPin  size={14} color={COLORS.green} />} text={`Zona ${request.location_city}`} />}
              {request?.genre        && <InfoRow icon={<Music    size={14} color={COLORS.green} />} text={request.genre} />}
              {request?.guest_count  && <InfoRow icon={<Users    size={14} color={COLORS.green} />} text={`≈${request.guest_count} invitados`} />}
            </Animated.View>

            {/* Countdown */}
            {lockState === 'locked' && countdown ? (
              <Animated.View style={{ opacity: itemFade[2] }}>
                <Animated.View style={[s.countdownRow, {
                  backgroundColor: curBg,
                  borderColor: curBorder,
                  transform: [{ translateX: cdShake }],
                }]}>
                  <Text style={[s.countdownLabel, { color: curColor }]}>Tiempo para cotizar</Text>
                  <Animated.Text style={[s.countdownValue, {
                    color: curColor,
                    transform: [{ scale: cdValueScale }],
                  }]}>
                    {countdown}
                  </Animated.Text>
                </Animated.View>
              </Animated.View>
            ) : (
              <Animated.View style={{ opacity: itemFade[2], height: 0 }} />
            )}

            {/* Primary CTA */}
            <Animated.View style={{ opacity: itemFade[3] }}>
              <Pressable
                style={[s.btnPrimary, lockState === 'locking' && { opacity: 0.6 },
                  // CTA glow pulse in critical zone handled via static shadow — no extra animation
                ]}
                onPress={handleCotizar}
                disabled={lockState === 'locking' || lockState === 'locked'}
              >
                {lockState === 'locking' ? (
                  // Mini spinner via rotation — no ActivityIndicator
                  <Text style={s.btnPrimaryText}>Bloqueando…</Text>
                ) : (
                  <Text style={s.btnPrimaryText}>
                    {lockState === 'locked' ? 'Cotizando…' : 'Cotizar ahora'}
                  </Text>
                )}
              </Pressable>
            </Animated.View>

            {/* Secondary */}
            <Animated.View style={{ opacity: itemFade[4] }}>
              <Pressable style={s.btnSecondary} onPress={handleIgnorar}>
                <Text style={s.btnSecondaryText}>No disponible</Text>
              </Pressable>
            </Animated.View>
          </>
        )}
      </Animated.View>
    </Animated.View>
  );
}

// ── TakenContent ──────────────────────────────────────────────────────────────
function TakenContent({ groupCount, onContinue }: { groupCount: number | null; onContinue: () => void }) {
  const slideAnim = useRef(new Animated.Value(28)).current;
  const fadeAnim  = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    Animated.parallel([
      Animated.timing(fadeAnim,  { toValue: 1, duration: 420, useNativeDriver: true }),
      Animated.timing(slideAnim, { toValue: 0, duration: 420, easing: Easing.out(Easing.cubic), useNativeDriver: true }),
    ]).start();
  }, []);

  return (
    <Animated.View style={[s.takenContent, { opacity: fadeAnim, transform: [{ translateY: slideAnim }] }]}>
      <Text style={s.takenIcon}>⚡</Text>
      <Text style={s.takenTitle}>Se fue.</Text>
      <Text style={s.takenBody}>Otro grupo envió su cotización primero.</Text>
      <Text style={s.takenCaption}>Así es esto — rápido.</Text>
      {groupCount !== null && groupCount > 1 && (
        <Text style={s.takenStat}>{groupCount} grupos recibieron esta solicitud.</Text>
      )}
      <Pressable style={s.btnContinue} onPress={onContinue}>
        <Text style={s.btnContinueText}>Seguir esperando</Text>
      </Pressable>
    </Animated.View>
  );
}

// ── QuotedContent ─────────────────────────────────────────────────────────────
function QuotedContent({ checkScale }: { checkScale: Animated.Value }) {
  const fadeAnim = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    Animated.timing(fadeAnim, { toValue: 1, duration: 380, useNativeDriver: true }).start();
  }, []);

  return (
    <Animated.View style={[s.quotedContent, { opacity: fadeAnim }]}>
      <Animated.View style={[s.checkCircle, { transform: [{ scale: checkScale }] }]}>
        <Text style={s.checkMark}>✓</Text>
      </Animated.View>
      <Text style={s.quotedTitle}>Cotización enviada.</Text>
      <Text style={s.quotedBody}>El cliente la está revisando ahora.</Text>
      <Text style={s.quotedSub}>Responderá en las próximas horas.</Text>
      <Text style={s.quotedHint}>Puedes cerrar esta pantalla.</Text>
    </Animated.View>
  );
}

// ── Styles ────────────────────────────────────────────────────────────────────
const s = StyleSheet.create({
  root:   { flex: 1, backgroundColor: '#040404' },

  // Map decorations
  glowBase: {
    position: 'absolute',
    width: 120, height: 120, borderRadius: 60,
    backgroundColor: 'rgba(0,230,118,0.25)',
    borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.35)',
  },
  pulse: {
    position: 'absolute',
    backgroundColor: 'rgba(0,230,118,0.18)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)',
  },
  pulseCenter: {
    width: 12, height: 12, borderRadius: 6,
    backgroundColor: COLORS.green,
    shadowColor: COLORS.green, shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 1, shadowRadius: 10, elevation: 8,
  },
  particle: {
    width: 7, height: 7, borderRadius: 3.5,
    backgroundColor: COLORS.green,
    shadowColor: COLORS.green, shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 1, shadowRadius: 5, elevation: 4,
  },
  originDot: {
    width: 20, height: 20, borderRadius: 10,
    backgroundColor: 'rgba(255,255,255,0.15)',
    borderWidth: 2, borderColor: '#fff',
    alignItems: 'center', justifyContent: 'center',
  },
  originInner: { width: 8, height: 8, borderRadius: 4, backgroundColor: '#fff' },

  // Ripple
  ripple: {
    position: 'absolute',
    width: 200, height: 200, borderRadius: 100,
    backgroundColor: COLORS.green,
    alignSelf: 'center',
    top: '35%',
  },

  // Gradients
  topGrad:    { position: 'absolute', top: 0, left: 0, right: 0, height: 160 },
  bottomGrad: { position: 'absolute', bottom: 0, left: 0, right: 0, height: 380 },

  // Top bar
  topBar: { position: 'absolute', top: 0, left: 0, right: 0 },
  topRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.lg,
    paddingTop: Platform.OS === 'android' ? SPACING.xl : 8,
    paddingBottom: 12,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: 'rgba(255,255,255,0.08)',
    alignItems: 'center', justifyContent: 'center',
  },
  expressBadge: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: 'rgba(0,230,118,0.12)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)',
    borderRadius: RADIUS.full, paddingHorizontal: 14, paddingVertical: 7,
  },
  expressBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green, letterSpacing: 1 },
  badgeDot: {
    width: 6, height: 6, borderRadius: 3,
    backgroundColor: COLORS.green, marginLeft: 7,
    shadowColor: COLORS.green, shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 1, shadowRadius: 4,
  },

  // Bottom sheet
  sheet: {
    position: 'absolute', bottom: 0, left: 0, right: 0,
    backgroundColor: 'rgba(8,12,8,0.97)',
    borderTopLeftRadius: 28, borderTopRightRadius: 28,
    borderTopWidth: 1, borderColor: 'rgba(0,230,118,0.15)',
    paddingHorizontal: SPACING.xl,
    paddingBottom: Platform.OS === 'ios' ? 36 : 24,
    paddingTop: 14,
  },
  handle: {
    width: 36, height: 4, borderRadius: 2,
    backgroundColor: 'rgba(255,255,255,0.18)',
    alignSelf: 'center', marginBottom: 20,
  },
  eventLabel: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, marginBottom: 16 },
  infoGrid:   { gap: 10, marginBottom: 20 },
  infoRow:    { flexDirection: 'row', alignItems: 'center', gap: 10 },
  infoText:   { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2, flex: 1 },

  countdownRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    borderWidth: 1, borderRadius: RADIUS.lg,
    paddingHorizontal: 16, paddingVertical: 10, marginBottom: 16,
  },
  countdownLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13 },
  countdownValue: { fontFamily: FONTS.title, fontSize: 20 },

  btnPrimary: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.xl,
    paddingVertical: 16, alignItems: 'center', marginBottom: 10,
    shadowColor: COLORS.green, shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.35, shadowRadius: 10, elevation: 6,
  },
  btnPrimaryText:   { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.bg },
  btnSecondary:     { borderRadius: RADIUS.xl, paddingVertical: 14, alignItems: 'center', borderWidth: 1, borderColor: 'rgba(255,255,255,0.1)' },
  btnSecondaryText: { fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.muted2 },

  // Taken
  takenContent: { alignItems: 'center', paddingVertical: 8, gap: 10 },
  takenIcon:    { fontSize: 44 },
  takenTitle:   { fontFamily: FONTS.title, fontSize: 28, color: COLORS.text },
  takenBody:    { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },
  takenCaption: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, fontStyle: 'italic' },
  takenStat:    { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginTop: 4 },
  btnContinue: {
    marginTop: 16, borderRadius: RADIUS.xl,
    paddingVertical: 14, paddingHorizontal: 40,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    alignItems: 'center',
  },
  btnContinueText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },

  // Quoted
  quotedContent: { alignItems: 'center', paddingVertical: 8, gap: 10 },
  checkCircle: {
    width: 72, height: 72, borderRadius: 36,
    backgroundColor: 'rgba(0,230,118,0.12)',
    borderWidth: 1.5, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
    shadowColor: COLORS.green, shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.5, shadowRadius: 16, elevation: 6,
    marginBottom: 4,
  },
  checkMark:    { fontSize: 32, color: COLORS.green },
  quotedTitle:  { fontFamily: FONTS.title, fontSize: 24, color: COLORS.text },
  quotedBody:   { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },
  quotedSub:    { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center' },
  quotedHint:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 8 },
});
