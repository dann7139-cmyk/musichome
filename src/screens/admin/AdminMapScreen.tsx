import { LinearGradient } from 'expo-linear-gradient';
import {
  ArrowLeft, Crosshair, List, Music, Radio, RefreshCw, SlidersHorizontal,
  Users, Wifi, WifiOff, X, Zap,
} from 'lucide-react-native';
import React, { useEffect, useMemo, useRef, useState } from 'react';
import Svg, { Defs, RadialGradient as SvgRadialGradient, Rect, Stop } from 'react-native-svg';
import {
  Animated,
  Dimensions,
  Easing,
  FlatList,
  Image,
  Modal,
  PanResponder,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import MapView, { Callout, Marker, Polyline, PROVIDER_GOOGLE, Region } from 'react-native-maps';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { EARTH_STYLE } from '../../constants/mapStyle';

// ─── Types ────────────────────────────────────────────────────────────────────

type MapMode = 'groups' | 'talents' | 'clients';
type GroupStatus = 'offline' | 'active' | 'in_event';
type StatusFilter = 'in_event' | 'active' | 'offline' | 'gps' | null;
// Nivel de detalle del marcador según zoom:
// dot (lejos) → mid (media distancia, círculo chico) → full (cerca, foto + etiquetas)
type MarkerTier = 'dot' | 'mid' | 'full';

interface GroupRow {
  group_id: string; group_name: string; profile_image: string | null;
  status: GroupStatus; hasGps: boolean; mapLat: number; mapLng: number;
  city: string | null; last_seen: string | null;
}

interface TalentRow {
  talent_id: string; full_name: string; avatar_url: string | null;
  instrument: string; availability: string;
  mapLat: number; mapLng: number; city: string | null; state: string | null;
  hasGps: boolean;
}

interface ClientRow {
  client_id: string; full_name: string; avatar_url: string | null;
  mapLat: number; mapLng: number; city: string | null; state: string | null;
  status: string;
}

interface ConnectionRow {
  reservationId: string;
  bookingType:   'express' | 'scheduled';
  eventStatus:   'en_route' | 'arrived' | 'playing';
  group: { id: string; name: string; avatar: string | null; lat: number; lng: number };
  client: { id: string; name: string; avatar: string | null; lat: number; lng: number };
}

// Ruta histórica visible en el mapa (un grupo a la vez)
interface RouteState {
  groupId: string; name: string; color: string;
  points: { latitude: number; longitude: number }[];
}

// Fila normalizada para el bottom sheet (cualquier modo)
interface SheetRow {
  id: string; name: string; image: string | null;
  city: string | null; statusColor: string; statusLabel: string;
  hasGps: boolean; lat: number; lng: number; distKm: number;
}

const STATUS: Record<GroupStatus, { color: string; label: string }> = {
  in_event: { color: COLORS.green, label: 'Tocando' },
  active:   { color: '#4CAF50',    label: 'En app'  },
  offline:  { color: '#666',       label: 'Offline' },
};

const GPS_BLUE = '#1A77F2';

// "Ver ruta" solo en grupos con GPS real y reserva activa (o in_event).
// Poner en false únicamente para pruebas sin reserva.
const ROUTE_REQUIRES_ACTIVE_BOOKING = true;

// ─── Viñeta — profundidad tipo globo: centro limpio, bordes oscurecidos ───────

function MapVignette() {
  return (
    <View style={StyleSheet.absoluteFillObject} pointerEvents="none">
      <Svg width="100%" height="100%">
        <Defs>
          <SvgRadialGradient id="vig" cx="50%" cy="44%" r="78%">
            <Stop offset="58%" stopColor="#000000" stopOpacity="0" />
            <Stop offset="86%" stopColor="#02060f" stopOpacity="0.28" />
            <Stop offset="100%" stopColor="#02060f" stopOpacity="0.6" />
          </SvgRadialGradient>
        </Defs>
        <Rect x="0" y="0" width="100%" height="100%" fill="url(#vig)" />
      </Svg>
    </View>
  );
}

// ─── Land fallback coords — never ocean ───────────────────────────────────────

const LAND_ANCHORS = [
  { lat: 19.43, lng: -99.13 },  { lat: 20.66, lng: -103.35 },
  { lat: 25.69, lng: -100.32 }, { lat: 19.04, lng: -98.21  },
  { lat: 20.97, lng: -89.62  }, { lat: 29.09, lng: -110.96 },
  { lat: 28.64, lng: -106.09 }, { lat: 22.16, lng: -100.99 },
  { lat: 21.88, lng: -102.30 }, { lat: 20.14, lng: -101.19 },
  { lat: 19.70, lng: -101.18 }, { lat: 18.92, lng: -99.23  },
  { lat: 17.07, lng: -96.72  }, { lat: 16.75, lng: -93.13  },
  { lat: 24.80, lng: -107.39 }, { lat: 32.65, lng: -115.47 },
];

const CITY_COORDS: Record<string, { lat: number; lng: number }> = {
  'guadalajara': { lat: 20.66, lng: -103.35 }, 'ciudad de méxico': { lat: 19.43, lng: -99.13 },
  'cdmx': { lat: 19.43, lng: -99.13 },         'monterrey': { lat: 25.69, lng: -100.32 },
  'tijuana': { lat: 32.51, lng: -117.04 },      'puebla': { lat: 19.04, lng: -98.21 },
  'jalisco': { lat: 20.66, lng: -103.35 },      'nuevo león': { lat: 25.69, lng: -100.32 },
  'bogotá': { lat: 4.71, lng: -74.07 },         'bogota': { lat: 4.71, lng: -74.07 },
  'miami': { lat: 25.76, lng: -80.19 },         'madrid': { lat: 40.42, lng: -3.70 },
  'buenos aires': { lat: -34.60, lng: -58.38 },
};

function resolveCoords(city: string | null | undefined, id: string) {
  if (city) {
    const k = city.toLowerCase().trim();
    if (CITY_COORDS[k]) return CITY_COORDS[k];
    for (const [key, v] of Object.entries(CITY_COORDS)) {
      if (k.includes(key) || key.includes(k)) return v;
    }
  }
  let h = 5381;
  for (let i = 0; i < id.length; i++) h = ((h << 5) + h + id.charCodeAt(i)) | 0;
  const a = LAND_ANCHORS[Math.abs(h) % LAND_ANCHORS.length];
  return {
    lat: a.lat + ((Math.abs((h * 31) ^ (h >> 3)) % 600) - 300) / 10000,
    lng: a.lng + ((Math.abs((h * 17) ^ (h >> 5)) % 600) - 300) / 10000,
  };
}

function timeAgo(iso: string | null) {
  if (!iso) return '';
  const m = Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
  if (m < 1) return 'ahora';
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

function haversineKm(lat1: number, lng1: number, lat2: number, lng2: number) {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLng = (lng2 - lng1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function formatDist(km: number) {
  return km < 1 ? `${Math.round(km * 1000)} m` : `${km < 100 ? km.toFixed(1) : Math.round(km)} km`;
}

// ─── Arc route helpers ────────────────────────────────────────────────────────

function lerpRoute(
  route: { latitude: number; longitude: number }[],
  t: number
) {
  const clamped = Math.max(0, Math.min(1, t));
  const idx = clamped * (route.length - 1);
  const lo  = Math.floor(idx);
  const hi  = Math.min(route.length - 1, lo + 1);
  const f   = idx - lo;
  return {
    latitude:  route[lo].latitude  + (route[hi].latitude  - route[lo].latitude)  * f,
    longitude: route[lo].longitude + (route[hi].longitude - route[lo].longitude) * f,
  };
}

function buildArcRoute(
  origin: { latitude: number; longitude: number },
  dest:   { latitude: number; longitude: number },
  curvature = 0.006
) {
  const pts: { latitude: number; longitude: number }[] = [];
  for (let i = 0; i <= 24; i++) {
    const t   = i / 24;
    const lat = origin.latitude  + (dest.latitude  - origin.latitude)  * t;
    const lng = origin.longitude + (dest.longitude - origin.longitude) * t;
    const c   = Math.sin(t * Math.PI) * curvature;
    pts.push({
      latitude:  lat - (dest.longitude - origin.longitude) * c,
      longitude: lng + (dest.latitude  - origin.latitude)  * c,
    });
  }
  return pts;
}

// ─── Clustering por celdas (sin librería) ────────────────────────────────────
// El tamaño de celda se cuantiza por bucket de zoom (log2 de latDelta) para que
// los clusters no cambien en cada micro-ajuste de cámara.

interface ClusterPoint { id: string; lat: number; lng: number; statusColor: string; statusPriority: number }
interface Cluster { key: string; lat: number; lng: number; ids: string[]; color: string }

function clusterize(points: ClusterPoint[], latDelta: number): Cluster[] {
  const bucket  = Math.max(-4, Math.round(Math.log2(Math.max(latDelta, 0.01))));
  const cellDeg = Math.pow(2, bucket) * 0.085;
  const cells = new Map<string, { latSum: number; lngSum: number; ids: string[]; colorCount: Map<string, { n: number; pri: number }> }>();

  for (const p of points) {
    const key = `${Math.floor(p.lat / cellDeg)}:${Math.floor(p.lng / cellDeg)}`;
    let c = cells.get(key);
    if (!c) { c = { latSum: 0, lngSum: 0, ids: [], colorCount: new Map() }; cells.set(key, c); }
    c.latSum += p.lat; c.lngSum += p.lng; c.ids.push(p.id);
    const cc = c.colorCount.get(p.statusColor);
    if (cc) cc.n += 1;
    else c.colorCount.set(p.statusColor, { n: 1, pri: p.statusPriority });
  }

  const out: Cluster[] = [];
  for (const [key, c] of cells) {
    // Color dominante: el más frecuente; empate → mayor prioridad de actividad
    let color = '#666'; let bestN = -1; let bestPri = -1;
    for (const [col, { n, pri }] of c.colorCount) {
      if (n > bestN || (n === bestN && pri > bestPri)) { color = col; bestN = n; bestPri = pri; }
    }
    out.push({ key, lat: c.latSum / c.ids.length, lng: c.lngSum / c.ids.length, ids: c.ids, color });
  }
  return out;
}

function ClusterBubble({ count, color, tier }: { count: number; color: string; tier: MarkerTier }) {
  // Tamaño del círculo escala con el zoom: lejos → pequeño, cerca → grande
  const sz =
    tier === 'dot'
      ? (count > 20 ? 30 : count > 8 ? 26 : 22)
      : tier === 'mid'
      ? (count > 20 ? 40 : count > 8 ? 36 : 30)
      : (count > 20 ? 52 : count > 8 ? 46 : 40);
  const fontSize = tier === 'dot' ? (count > 99 ? 9 : 11) : (count > 99 ? 11 : 14);
  return (
    <View style={{ width: sz + 10, height: sz + 10, alignItems: 'center', justifyContent: 'center' }}>
      <View style={{
        position: 'absolute', width: sz + 10, height: sz + 10, borderRadius: (sz + 10) / 2,
        backgroundColor: `${color}1e`,
      }} />
      <View style={{
        width: sz, height: sz, borderRadius: sz / 2,
        backgroundColor: 'rgba(10,16,30,0.92)',
        borderWidth: tier === 'dot' ? 1.5 : 2, borderColor: color,
        alignItems: 'center', justifyContent: 'center',
      }}>
        <Text style={{ color, fontFamily: FONTS.title, fontSize }}>
          {count > 99 ? '99+' : count}
        </Text>
      </View>
    </View>
  );
}

// ─── Constants ────────────────────────────────────────────────────────────────

const { height: H } = Dimensions.get('window');
const SHEET_H = Math.round(H * 0.52);

const MEXICO_REGION: Region = {
  latitude: 23.5, longitude: -102.5, latitudeDelta: 26, longitudeDelta: 26,
};

// Cámara de la sesión: persiste mientras la app viva. La intro cinematográfica
// solo corre la primera vez; al volver a entrar se restaura la última posición.
let sessionCamera: Region | null = null;

// ─── Live pulse dot ───────────────────────────────────────────────────────────

function LivePulse() {
  const sc = useRef(new Animated.Value(1)).current;
  const op = useRef(new Animated.Value(0.7)).current;
  useEffect(() => {
    Animated.loop(Animated.sequence([
      Animated.parallel([
        Animated.timing(sc, { toValue: 1.7, duration: 700, easing: Easing.out(Easing.ease), useNativeDriver: true }),
        Animated.timing(op, { toValue: 0, duration: 700, useNativeDriver: true }),
      ]),
      Animated.parallel([
        Animated.timing(sc, { toValue: 1, duration: 0, useNativeDriver: true }),
        Animated.timing(op, { toValue: 0.7, duration: 0, useNativeDriver: true }),
      ]),
      Animated.delay(550),
    ])).start();
  }, []);
  return (
    <View style={{ width: 12, height: 12, alignItems: 'center', justifyContent: 'center' }}>
      <Animated.View style={{
        position: 'absolute', width: 12, height: 12, borderRadius: 6,
        backgroundColor: COLORS.green, transform: [{ scale: sc }], opacity: op,
      }} />
      <View style={{ width: 7, height: 7, borderRadius: 3.5, backgroundColor: COLORS.green }} />
    </View>
  );
}

// ─── Anillo pulsante para marcadores "tocando" ───────────────────────────────
// Solo se monta en marcadores in_event, que llevan tracksViewChanges activo.

function PulseRing({ size, color }: { size: number; color: string }) {
  const sc = useRef(new Animated.Value(1)).current;
  const op = useRef(new Animated.Value(0.85)).current;
  useEffect(() => {
    Animated.loop(Animated.sequence([
      Animated.parallel([
        Animated.timing(sc, { toValue: 1.45, duration: 1100, easing: Easing.out(Easing.ease), useNativeDriver: true }),
        Animated.timing(op, { toValue: 0,    duration: 1100, useNativeDriver: true }),
      ]),
      Animated.parallel([
        Animated.timing(sc, { toValue: 1,    duration: 0, useNativeDriver: true }),
        Animated.timing(op, { toValue: 0.85, duration: 0, useNativeDriver: true }),
      ]),
      Animated.delay(250),
    ])).start();
  }, []);
  return (
    <Animated.View style={{
      position: 'absolute',
      width: size, height: size, borderRadius: size / 2,
      borderWidth: 2, borderColor: color,
      transform: [{ scale: sc }], opacity: op,
    }} />
  );
}

// ─── Group marker ─────────────────────────────────────────────────────────────

function GroupMarker({ status, profileImage, name, hasGps, tier, eventStatus, bookingType }: {
  status: GroupStatus; profileImage: string | null; name: string; hasGps: boolean; tier: MarkerTier;
  eventStatus?: 'en_route' | 'arrived' | 'playing' | null;
  bookingType?: 'express' | 'scheduled' | null;
}) {
  const cfg      = STATUS[status];
  const isLive   = status !== 'offline';
  const hasEvent = !!eventStatus;

  // Event-aware ring color
  const ringColor = !hasEvent ? cfg.color
    : eventStatus === 'playing'  ? COLORS.green
    : eventStatus === 'arrived'  ? '#4CAF50'
    : bookingType  === 'express' ? '#FF6D00'
    : '#7C4DFF';

  // Lejos: punto pequeño — el detalle vive en mid/full
  if (tier === 'dot') {
    return (
      <View style={{
        width: 12, height: 12, borderRadius: 6,
        backgroundColor: isLive ? ringColor : '#444',
        borderWidth: 2, borderColor: isLive ? '#fff' : '#666',
      }} />
    );
  }

  const full  = tier === 'full';
  // Tamaños 52/42 solo de cerca; a media distancia círculo compacto
  const sz    = full ? (hasGps ? 52 : 42) : (hasGps ? 30 : 24);
  const outer = sz + (full ? 20 : 10);
  const init  = name.trim()[0]?.toUpperCase() ?? '?';
  return (
    <View style={{ alignItems: 'center' }}>
      {/* Contenedor con tamaño fijo que contiene el glow correctamente */}
      <View style={{ width: outer, height: outer, alignItems: 'center', justifyContent: 'center' }}>
        {/* Glow sutil — solo activos */}
        {isLive && (
          <View style={{
            position: 'absolute',
            width: sz + (full ? 12 : 6), height: sz + (full ? 12 : 6),
            borderRadius: (sz + (full ? 12 : 6)) / 2,
            backgroundColor: `${ringColor}30`,
          }} />
        )}
        {/* Anillo pulsante — solo tocando y de cerca */}
        {full && status === 'in_event' && <PulseRing size={sz + 10} color={ringColor} />}
        <View style={{
          width: sz, height: sz, borderRadius: sz / 2,
          borderWidth: 2,
          borderColor: isLive ? ringColor : '#666',
          overflow: 'hidden', backgroundColor: '#0e2412',
        }}>
          {profileImage
            ? <Image source={{ uri: profileImage }} style={{ width: sz, height: sz }} resizeMode="cover" />
            : (
              <View style={{ width: sz, height: sz, alignItems: 'center', justifyContent: 'center', backgroundColor: '#13151c' }}>
                <Text style={{ color: isLive ? ringColor : '#888', fontFamily: FONTS.title, fontSize: full ? (sz > 46 ? 17 : 14) : 11 }}>{init}</Text>
              </View>
            )
          }
        </View>
      </View>
      {/* Etiqueta de evento — solo de cerca, a media distancia satura el mapa */}
      {full && hasEvent && (
        <View style={{
          marginTop: 2, backgroundColor: 'rgba(10,16,30,0.9)',
          borderRadius: 6, borderWidth: 1, borderColor: `${ringColor}66`,
          paddingHorizontal: 5, paddingVertical: 2,
        }}>
          <Text style={{ fontSize: 9, color: ringColor, fontFamily: FONTS.bodySemiBold }}>
            {eventStatus === 'playing' ? '🎸 Tocando' : eventStatus === 'arrived' ? '📍 Llegó' : '🚗 En camino'}
          </Text>
        </View>
      )}
    </View>
  );
}

// ─── Talent marker ────────────────────────────────────────────────────────────

const TALENT_COLOR = '#9C27B0';

function TalentMarker({ avatarUrl, name, availability, hasGps, tier }: {
  avatarUrl: string | null; name: string; availability: string; hasGps: boolean; tier: MarkerTier;
}) {
  const isAvail = availability === 'available';
  const color   = isAvail ? TALENT_COLOR : '#777';
  const init    = name.trim()[0]?.toUpperCase() ?? '?';

  if (tier === 'dot') {
    return (
      <View style={{ width: 12, height: 12, borderRadius: 6, backgroundColor: color, borderWidth: 2, borderColor: '#fff' }} />
    );
  }

  const full = tier === 'full';
  const sz   = full ? 52 : 28;
  const box  = full ? 68 : 38;
  return (
    <View style={{ width: box, height: box, alignItems: 'center', justifyContent: 'center' }}>
      {/* Glow sutil — solo disponibles */}
      {isAvail && (
        <View style={{
          position: 'absolute', width: sz + 12, height: sz + 12, borderRadius: (sz + 12) / 2,
          backgroundColor: `${TALENT_COLOR}28`,
        }} />
      )}
      {/* Photo circle */}
      <View style={{
        width: sz, height: sz, borderRadius: sz / 2,
        borderWidth: 2, borderColor: color,
        overflow: 'hidden', backgroundColor: '#1a0030',
      }}>
        {avatarUrl
          ? <Image source={{ uri: avatarUrl }} style={{ width: '100%', height: '100%' }} resizeMode="cover" />
          : (
            <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: `${color}30` }}>
              <Text style={{ color, fontFamily: FONTS.title, fontSize: full ? 18 : 11 }}>{init}</Text>
            </View>
          )
        }
      </View>
      {/* GPS badge — solo de cerca */}
      {full && (
        <View style={{
          position: 'absolute', bottom: 2, right: 2,
          width: 16, height: 16, borderRadius: 8,
          backgroundColor: hasGps ? TALENT_COLOR : '#555',
          alignItems: 'center', justifyContent: 'center',
          borderWidth: 1.5, borderColor: '#fff',
        }}>
          <Text style={{ fontSize: 9, color: '#fff' }}>♪</Text>
        </View>
      )}
    </View>
  );
}

// ─── Client marker ────────────────────────────────────────────────────────────

const CLIENT_COLOR = '#FF6D00';

function ClientMarker({ avatarUrl, name, status, tier }: {
  avatarUrl: string | null; name: string; status: string; tier: MarkerTier;
}) {
  const isActive = status === 'active';
  const init     = name.trim()[0]?.toUpperCase() ?? '?';

  if (tier === 'dot') {
    return (
      <View style={{
        width: 12, height: 12, borderRadius: 6,
        backgroundColor: isActive ? CLIENT_COLOR : '#555',
        borderWidth: 2, borderColor: '#fff',
      }} />
    );
  }

  const full = tier === 'full';
  const sz   = full ? 48 : 26;
  return (
    <View style={{ alignItems: 'center' }}>
      {isActive && (
        <View style={{
          position: 'absolute',
          width: sz + 12, height: sz + 12, borderRadius: (sz + 12) / 2,
          backgroundColor: `${CLIENT_COLOR}30`,
          top: -6, left: -6,
        }} />
      )}
      <View style={{
        width: sz, height: sz, borderRadius: sz / 2,
        borderWidth: 2, borderColor: isActive ? CLIENT_COLOR : '#666',
        overflow: 'hidden', backgroundColor: '#2a1800',
      }}>
        {avatarUrl
          ? <Image source={{ uri: avatarUrl }} style={{ width: '100%', height: '100%' }} resizeMode="cover" />
          : (
            <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: `${CLIENT_COLOR}30` }}>
              <Text style={{ color: CLIENT_COLOR, fontFamily: FONTS.title, fontSize: full ? 16 : 11 }}>{init}</Text>
            </View>
          )
        }
      </View>
      {/* Person badge — solo de cerca */}
      {full && (
        <View style={{
          position: 'absolute', bottom: -4, right: -4,
          width: 16, height: 16, borderRadius: 8,
          backgroundColor: CLIENT_COLOR, alignItems: 'center', justifyContent: 'center',
          borderWidth: 1.5, borderColor: '#fff',
        }}>
          <Text style={{ fontSize: 8, color: '#fff' }}>♟</Text>
        </View>
      )}
    </View>
  );
}

// ─── Connection arc components ───────────────────────────────────────────────

function ConnectionParticle({
  route, delay, color, noteChar, speed,
}: {
  route: { latitude: number; longitude: number }[];
  delay: number; color: string; noteChar: string; speed: number;
}) {
  const [pos, setPos] = useState(route[0] ?? { latitude: 0, longitude: 0 });
  // Ref de ruta: se actualiza sin reiniciar el loop rAF.
  // Cuando el GPS actualiza las coordenadas del arco, la nota continúa
  // su trayectoria sin saltar de vuelta al origen.
  const routeRef = useRef(route);

  useEffect(() => {
    routeRef.current = route;
  }, [route]);

  useEffect(() => {
    const THROTTLE = 250; // ms — 4fps
    let startTime: number | null = null;
    let lastUpdate = 0;
    let frameId: number;
    const delayEnd = Date.now() + delay;

    const tick = (now: number) => {
      frameId = requestAnimationFrame(tick);
      if (Date.now() < delayEnd) return;
      if (startTime === null) startTime = now;
      if (now - lastUpdate < THROTTLE) return;
      lastUpdate = now;
      const r = routeRef.current;
      if (r.length < 2) return;
      const t = ((now - startTime) % speed) / speed;
      setPos(lerpRoute(r, t));
    };

    frameId = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frameId);
  }, [delay, speed]); // route NO en deps — el ref lo maneja sin reiniciar el loop

  return (
    <Marker coordinate={pos} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}>
      <Text style={{
        fontSize: 12, color,
        textShadowColor: color, textShadowOffset: { width: 0, height: 0 }, textShadowRadius: 4,
      }}>
        {noteChar}
      </Text>
    </Marker>
  );
}

function ClientConnectionMarker({ avatarUrl, name, eventStatus, bookingType, tier }: {
  avatarUrl: string | null; name: string;
  eventStatus: string; bookingType: string; tier: MarkerTier;
}) {
  const color = bookingType === 'express' ? '#FF6D00' : '#7C4DFF';
  const init  = name.trim()[0]?.toUpperCase() ?? '?';

  if (tier === 'dot') {
    return (
      <View style={{
        width: 10, height: 10, borderRadius: 5,
        backgroundColor: color, borderWidth: 1.5, borderColor: '#fff',
      }} />
    );
  }

  const full = tier === 'full';
  const sz   = full ? 48 : 26;
  return (
    <View style={{ alignItems: 'center' }}>
      <View style={{
        position: 'absolute', width: sz + 14, height: sz + 14, borderRadius: (sz + 14) / 2,
        backgroundColor: `${color}25`, top: -7, left: -7,
      }} />
      <View style={{
        width: sz, height: sz, borderRadius: sz / 2,
        borderWidth: full ? 2.5 : 2, borderColor: color,
        overflow: 'hidden', backgroundColor: '#1a0010',
      }}>
        {avatarUrl
          ? <Image source={{ uri: avatarUrl }} style={{ width: '100%', height: '100%' }} resizeMode="cover" />
          : (
            <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: `${color}30` }}>
              <Text style={{ color, fontFamily: FONTS.title, fontSize: full ? 16 : 11 }}>{init}</Text>
            </View>
          )
        }
      </View>
      {full && (
        <View style={{
          marginTop: 2, backgroundColor: `${color}22`,
          borderRadius: 6, borderWidth: 1, borderColor: `${color}55`,
          paddingHorizontal: 4, paddingVertical: 1,
        }}>
          <Text style={{ fontSize: 8, color, fontFamily: FONTS.bodySemiBold }}>
            {eventStatus === 'playing' ? '🎵 En evento' : '📍 Destino'}
          </Text>
        </View>
      )}
    </View>
  );
}

function EventArc({
  connection, regime,
}: {
  connection: ConnectionRow;
  regime: 'full' | 'medium' | 'lite' | 'minimal';
}) {
  const isExpress = connection.bookingType === 'express';
  const isPlaying = connection.eventStatus === 'playing';

  const routePts = useMemo(() => buildArcRoute(
    { latitude: connection.group.lat, longitude: connection.group.lng },
    { latitude: connection.client.lat, longitude: connection.client.lng },
    isExpress ? 0.008 : 0.005
  ), [
    connection.group.lat, connection.group.lng,
    connection.client.lat, connection.client.lng,
    isExpress,
  ]);

  const arcColors = isExpress
    ? { outer: 'rgba(255,109,0,0.08)', inner: 'rgba(255,109,0,0.22)', solid: 'rgba(255,109,0,0.90)' }
    : { outer: 'rgba(124,77,255,0.07)', inner: 'rgba(124,77,255,0.18)', solid: 'rgba(124,77,255,0.88)' };

  const noteChar    = isExpress ? '♪' : '♫';
  const noteColor   = isExpress ? '#FF6D00' : '#9C27B0';
  const baseSpeed   = isExpress ? 1100 : 2400;
  const particleSpd = isPlaying ? Math.floor(baseSpeed * 0.65) : baseSpeed;
  const strokeW     = isExpress ? 3 : 2.5;

  if (regime === 'minimal' || routePts.length < 2) return null;

  return (
    <>
      {regime === 'full' && (
        <Polyline coordinates={routePts} strokeWidth={22} strokeColor={arcColors.outer} />
      )}
      {(regime === 'full' || regime === 'medium') && (
        <Polyline coordinates={routePts} strokeWidth={9} strokeColor={arcColors.inner} />
      )}
      <Polyline
        coordinates={routePts}
        strokeWidth={strokeW}
        strokeColor={arcColors.solid}
        {...(isExpress && Platform.OS === 'ios' ? { lineDashPattern: [5, 4] } : {})}
      />
      {regime === 'full' && (
        <>
          <ConnectionParticle route={routePts} delay={0}                        color={noteColor} noteChar={noteChar} speed={particleSpd} />
          <ConnectionParticle route={routePts} delay={Math.floor(particleSpd / 3)}  color={noteColor} noteChar={noteChar} speed={particleSpd} />
          {isExpress && (
            <ConnectionParticle route={routePts} delay={Math.floor(particleSpd / 3 * 2)} color={noteColor} noteChar={noteChar} speed={particleSpd} />
          )}
        </>
      )}
    </>
  );
}

// ─── Stat chip flotante (tappable, filtra el mapa) ───────────────────────────

function StatChip({ icon, label, count, color, active, prominent, onPress }: {
  icon: React.ReactNode; label: string; count: number; color: string;
  active: boolean; prominent?: boolean; onPress: () => void;
}) {
  return (
    <Pressable
      onPress={onPress}
      // hitSlop lleva el target a ≥44px sin agrandar lo visual
      hitSlop={{ top: 10, bottom: 10, left: 4, right: 4 }}
      style={[
        s.chip,
        prominent && s.chipProminent,
        { borderColor: active ? color : prominent ? `${color}66` : `${color}45` },
        // El chip prominente lleva tinte permanente; activo lo intensifica
        prominent && { backgroundColor: `${color}1C` },
        active && { backgroundColor: `${color}30` },
      ]}
    >
      {icon}
      <Text style={[s.chipN, { color }, prominent && { fontSize: 18 }]}>{count}</Text>
      <Text style={[s.chipL, prominent && { fontSize: 11.5, color: `${color}CC` }, active && { color }]}>{label}</Text>
    </Pressable>
  );
}

// ─── Screen ───────────────────────────────────────────────────────────────────

export default function AdminMapScreen({ navigation }: any) {
  const insets = useSafeAreaInsets();
  const [mode,        setMode]       = useState<MapMode>('groups');
  const [groups,      setGroups]     = useState<GroupRow[]>([]);
  const [talents,     setTalents]    = useState<TalentRow[]>([]);
  const [clients,     setClients]    = useState<ClientRow[]>([]);
  const [connections, setConnections] = useState<ConnectionRow[]>([]);
  const [loading,     setLoading]    = useState(true);
  const [region,      setRegion]     = useState<Region>({
    latitude: 23.5, longitude: -102.5, latitudeDelta: 26, longitudeDelta: 26,
  });
  // Filtros — persisten al cambiar entre tabs Grupos/Talentos/Clientes
  const [statusFilter, setStatusFilter] = useState<StatusFilter>(null);
  const [cityFilter,   setCityFilter]   = useState<string | null>(null);
  const [filterOpen,   setFilterOpen]   = useState(false);
  // Ruta histórica — ref espejo para leerla desde handlers Realtime sin closure stale
  const [route, setRoute] = useState<RouteState | null>(null);
  const routeRef = useRef<RouteState | null>(null);
  const mapRef              = useRef<MapView>(null);
  const channelRef          = useRef<ReturnType<typeof supabase.channel> | null>(null);
  const connRefreshRef      = useRef<ReturnType<typeof setInterval> | null>(null);
  // Ref espejo de connections: permite que los handlers Realtime lean el estado
  // actual sin capturar closures stale, y sin forzar re-renders cuando el grupo
  // afectado no está en ninguna conexión activa.
  const connectionsRef      = useRef<ConnectionRow[]>([]);

  // Nivel de detalle por zoom:
  // latDelta > 8 → puntos; 2.8-8 → círculos chicos; < 2.8 → foto completa + etiquetas
  const latDelta = region.latitudeDelta;
  const tier: MarkerTier = latDelta > 8 ? 'dot' : latDelta > 2.8 ? 'mid' : 'full';
  const sizeKey = tier; // key suffix to force marker remount on zoom tier change

  // ── Bottom sheet (Animated + PanResponder, sin deps nuevas) ──
  // Cerrado queda fuera de pantalla por completo — se abre con el FAB de lista
  const sheetClosed = SHEET_H + 24;
  const sheetY      = useRef(new Animated.Value(sheetClosed)).current;
  const sheetOpenRef = useRef(false);
  const [sheetOpen, setSheetOpen] = useState(false);

  const snapSheet = (open: boolean) => {
    sheetOpenRef.current = open;
    setSheetOpen(open);
    Animated.spring(sheetY, {
      toValue: open ? 0 : sheetClosed,
      tension: 60, friction: 12, useNativeDriver: true,
    }).start();
  };

  const panResponder = useRef(
    PanResponder.create({
      onMoveShouldSetPanResponder: (_, g) => Math.abs(g.dy) > 6,
      onPanResponderMove: (_, g) => {
        const base = sheetOpenRef.current ? 0 : sheetClosed;
        sheetY.setValue(Math.min(sheetClosed, Math.max(0, base + g.dy)));
      },
      onPanResponderRelease: (_, g) => {
        let open: boolean;
        if (g.vy < -0.4) open = true;
        else if (g.vy > 0.4) open = false;
        else {
          const pos = (sheetOpenRef.current ? 0 : sheetClosed) + g.dy;
          open = pos < sheetClosed / 2;
        }
        snapSheet(open);
      },
    })
  ).current;

  // Intro de cámara: solo en la primera apertura de la sesión, saltable con tap.
  // Reentradas: directo a la última cámara guardada.
  const firstOpenRef = useRef(sessionCamera === null);
  const [introActive, setIntroActive] = useState(sessionCamera === null);
  const introTimers = useRef<ReturnType<typeof setTimeout>[]>([]);

  useEffect(() => {
    if (!firstOpenRef.current) {
      const t = setTimeout(() => {
        if (sessionCamera) mapRef.current?.animateToRegion(sessionCamera, 0);
      }, 80);
      return () => clearTimeout(t);
    }
    const t1 = setTimeout(() => {
      mapRef.current?.animateToRegion(
        { latitude: 10, longitude: -50, latitudeDelta: 140, longitudeDelta: 140 }, 0
      );
    }, 350);
    const t2 = setTimeout(() => {
      mapRef.current?.animateToRegion(MEXICO_REGION, 2200);
    }, 850);
    const t3 = setTimeout(() => setIntroActive(false), 3200);
    introTimers.current = [t1, t2, t3];
    return () => introTimers.current.forEach(clearTimeout);
  }, []);

  const skipIntro = () => {
    introTimers.current.forEach(clearTimeout);
    setIntroActive(false);
    mapRef.current?.animateToRegion(MEXICO_REGION, 350);
  };

  const fetchAll = async () => {
    const [{ data: allGroups }, { data: locs }, { data: activeRes }] = await Promise.all([
      supabase.from('groups').select('id, name, profile_image, city').order('name'),
      supabase.from('group_locations').select('group_id, lat, lng, city, status, last_seen'),
      supabase.from('reservations').select('group_id').eq('status', 'in_progress'),
    ]);
    if (!allGroups) { setLoading(false); return; }

    const locMap  = new Map<string, any>((locs ?? []).map(l => [l.group_id, l]));
    const inEvent = new Set<string>((activeRes ?? []).map((r: any) => r.group_id));

    const merged: GroupRow[] = allGroups.map((g: any) => {
      const loc = locMap.get(g.id);
      let status: GroupStatus = 'offline';
      if (inEvent.has(g.id) || loc?.status === 'in_event') status = 'in_event';
      else if (loc?.status === 'active') status = 'active';

      const hasGps   = !!(loc?.lat && loc?.lng);
      const cityName = loc?.city ?? g.city ?? null;
      const pos      = hasGps
        ? { lat: loc.lat as number, lng: loc.lng as number }
        : resolveCoords(cityName, g.id);

      return {
        group_id: g.id, group_name: g.name ?? 'Grupo',
        profile_image: g.profile_image ?? null,
        status, hasGps, mapLat: pos.lat, mapLng: pos.lng,
        city: cityName, last_seen: loc?.last_seen ?? null,
      };
    });

    const ord: Record<GroupStatus, number> = { in_event: 0, active: 1, offline: 2 };
    merged.sort((a, b) => ord[a.status] - ord[b.status]);
    setGroups(merged);
    setLoading(false);
  };

  const fetchTalents = async () => {
    setLoading(true);
    // Primary: talent_locations (GPS real desde la app, últimas 24h)
    const { data: liveData } = await supabase.rpc('get_talent_locations');
    // Fallback: job_board_profiles con lat/lng manual (si no tienen location en vivo)
    const { data: jbpData } = await supabase
      .from('job_board_profiles')
      .select(`
        id, user_id, instrument_or_role, availability_status, lat, lng,
        profile:profiles!job_board_profiles_user_id_fkey(full_name, avatar_url, city, state)
      `)
      .eq('is_visible', true)
      .not('lat', 'is', null)
      .not('lng', 'is', null);

    const liveIds = new Set<string>((liveData ?? []).map((l: any) => l.user_id));
    const rows: TalentRow[] = [];

    // GPS real (talent_locations) — prioridad, punto exacto
    for (const l of (liveData ?? []) as any[]) {
      rows.push({
        talent_id:    l.user_id,
        full_name:    l.full_name ?? 'Talento',
        avatar_url:   l.avatar_url ?? null,
        instrument:   l.instrument ?? '—',
        availability: l.availability ?? 'unknown',
        mapLat:       l.lat,
        mapLng:       l.lng,
        city:         l.city ?? null,
        state:        l.state ?? null,
        hasGps:       true,
      });
    }

    // Fallback: talentos sin GPS live — ubicación aproximada por estado/ciudad del perfil
    for (const t of (jbpData ?? []) as any[]) {
      if (liveIds.has(t.user_id)) continue;
      const city  = t.profile?.city  ?? null;
      const state = t.profile?.state ?? null;
      // Use resolveCoords from profile state/city — ignores arbitrary SQL test coords
      const pos   = resolveCoords(state ?? city, t.user_id);
      rows.push({
        talent_id:    t.user_id,
        full_name:    t.profile?.full_name ?? 'Talento',
        avatar_url:   t.profile?.avatar_url ?? null,
        instrument:   t.instrument_or_role ?? '—',
        availability: t.availability_status ?? 'unknown',
        mapLat:       pos.lat,
        mapLng:       pos.lng,
        city,
        state,
        hasGps:       false,
      });
    }

    setTalents(rows);
    setLoading(false);
  };

  const fetchClients = async () => {
    setLoading(true);
    const { data, error } = await supabase.rpc('get_client_locations');
    if (error) {
      console.warn('[AdminMap] get_client_locations error:', error.message);
      setClients([]);
      setLoading(false);
      return;
    }
    const rows: ClientRow[] = ((data as any[]) ?? []).map(c => ({
      client_id:  c.user_id,
      full_name:  c.full_name ?? 'Cliente',
      avatar_url: c.avatar_url ?? null,
      mapLat:     typeof c.lat === 'number' ? c.lat : 0,
      mapLng:     typeof c.lng === 'number' ? c.lng : 0,
      city:       c.city  ?? null,
      state:      c.state ?? null,
      status:     c.status ?? 'offline',
    })).filter(c => c.mapLat !== 0 || c.mapLng !== 0); // descartar filas sin coords
    setClients(rows);
    setLoading(false);
  };

  const fetchConnections = async () => {
    const { data, error } = await supabase.rpc('get_active_booking_connections');
    if (error) return; // silencioso — se reintenta en 60s
    const rows: ConnectionRow[] = ((data as any[]) ?? []).map(c => ({
      reservationId: c.reservation_id,
      bookingType:   c.booking_type   as 'express' | 'scheduled',
      eventStatus:   c.event_status   as 'en_route' | 'arrived' | 'playing',
      group:  { id: c.group_id,  name: c.group_name  ?? 'Grupo',   avatar: c.group_avatar  ?? null, lat: c.group_lat,  lng: c.group_lng  },
      client: { id: c.client_id, name: c.client_name ?? 'Cliente', avatar: c.client_avatar ?? null, lat: c.client_lat, lng: c.client_lng },
    }));
    connectionsRef.current = rows;
    setConnections(rows);
  };

  const handleRegionChange = (r: Region) => {
    setRegion(r);
    sessionCamera = r; // recordar la cámara para reentradas en la misma sesión
  };

  const handleModeSwitch = (m: MapMode) => {
    setMode(m);
    routeRef.current = null;
    setRoute(null); // la ruta es de grupos — no tiene sentido en otros tabs
    if (m === 'talents') fetchTalents();
    else if (m === 'clients') fetchClients();
    else fetchAll();
  };

  useEffect(() => {
    fetchAll();
    fetchConnections();

    channelRef.current = supabase
      .channel('admin-globe')

      // group_locations — incremental: solo actualiza lat/lng/status del grupo afectado
      .on('postgres_changes', { event: '*', schema: 'public', table: 'group_locations' }, (payload: any) => {
        const row = payload.new;
        if (!row?.group_id) return;
        const hasGps = !!(row.lat && row.lng);
        setGroups(prev => prev.map(g => {
          if (g.group_id !== row.group_id) return g;
          const newStatus: GroupStatus = g.status === 'in_event'
            ? 'in_event'
            : (row.status === 'active' ? 'active' : 'offline');
          return {
            ...g,
            mapLat:    hasGps ? (row.lat as number) : g.mapLat,
            mapLng:    hasGps ? (row.lng as number) : g.mapLng,
            hasGps,
            status:    newStatus,
            city:      row.city ?? g.city,
            last_seen: row.last_seen ?? g.last_seen,
          };
        }));
        // Sincronizar coords del grupo en conexiones activas — solo si está en una
        if (hasGps && connectionsRef.current.some(c => c.group.id === row.group_id)) {
          setConnections(prev => {
            const next = prev.map(conn =>
              conn.group.id === row.group_id
                ? { ...conn, group: { ...conn.group, lat: row.lat, lng: row.lng } }
                : conn
            );
            connectionsRef.current = next;
            return next;
          });
        }
        // Si la ruta de este grupo está visible, extenderla en vivo
        const curRoute = routeRef.current;
        if (hasGps && curRoute && curRoute.groupId === row.group_id) {
          const next: RouteState = {
            ...curRoute,
            points: [...curRoute.points, { latitude: row.lat as number, longitude: row.lng as number }],
          };
          routeRef.current = next;
          setRoute(next);
        }
      })

      // reservations — poco frecuente: re-fetch completo + conexiones
      .on('postgres_changes', { event: '*', schema: 'public', table: 'reservations' }, () => {
        fetchAll();
        fetchConnections();
      })

      // talent_locations — incremental: solo actualiza lat/lng del talento
      .on('postgres_changes', { event: '*', schema: 'public', table: 'talent_locations' }, (payload: any) => {
        const row = payload.new;
        if (!row?.user_id) return;
        const hasGps = !!(row.lat && row.lng);
        setTalents(prev => prev.map(t =>
          t.talent_id !== row.user_id ? t : {
            ...t,
            mapLat: hasGps ? (row.lat as number) : t.mapLat,
            mapLng: hasGps ? (row.lng as number) : t.mapLng,
            hasGps,
          }
        ));
      })

      // client_locations — incremental: solo actualiza lat/lng/status del cliente
      .on('postgres_changes', { event: '*', schema: 'public', table: 'client_locations' }, (payload: any) => {
        const row = payload.new;
        if (!row?.user_id) return;
        const hasGps = !!(row.lat && row.lng);
        setClients(prev => prev.map(c =>
          c.client_id !== row.user_id ? c : {
            ...c,
            mapLat: hasGps ? (row.lat as number) : c.mapLat,
            mapLng: hasGps ? (row.lng as number) : c.mapLng,
            status: row.status ?? c.status,
          }
        ));
        // Sincronizar coords del cliente en conexiones activas — solo si está en una
        if (hasGps && connectionsRef.current.some(c => c.client.id === row.user_id)) {
          setConnections(prev => {
            const next = prev.map(conn =>
              conn.client.id === row.user_id
                ? { ...conn, client: { ...conn.client, lat: row.lat, lng: row.lng } }
                : conn
            );
            connectionsRef.current = next;
            return next;
          });
        }
      })

      .subscribe();

    return () => { if (channelRef.current) supabase.removeChannel(channelRef.current); };
  }, []);

  // Refresco de conexiones cada 60 segundos (el RPC valida ventana 10 min)
  useEffect(() => {
    connRefreshRef.current = setInterval(fetchConnections, 60_000);
    return () => { if (connRefreshRef.current) clearInterval(connRefreshRef.current); };
  }, []);

  useEffect(() => {
    // Auto-fit solo en la primera apertura — en reentradas respeta la cámara guardada
    if (!firstOpenRef.current) return;
    if (mode !== 'groups' || !groups.length || !mapRef.current) return;
    const coords = groups.map(g => ({ latitude: g.mapLat, longitude: g.mapLng }));
    const t = setTimeout(() => {
      mapRef.current?.fitToCoordinates(coords, {
        edgePadding: { top: 180, right: 60, bottom: 140, left: 60 }, animated: true,
      });
    }, 950);
    return () => clearTimeout(t);
  }, [groups.length]);

  // Talentos y clientes NO hacen auto-zoom al cargar — el usuario controla el mapa

  const flyToActive = () => {
    if (mode === 'groups') {
      const t = groups.find(g => g.hasGps && g.status !== 'offline')
             ?? groups.find(g => g.status !== 'offline');
      if (t) mapRef.current?.animateToRegion(
        { latitude: t.mapLat, longitude: t.mapLng, latitudeDelta: 0.8, longitudeDelta: 0.8 }, 900
      );
    } else if (mode === 'talents') {
      const t = talents.find(t => t.availability === 'available') ?? talents[0];
      if (t) mapRef.current?.animateToRegion(
        { latitude: t.mapLat, longitude: t.mapLng, latitudeDelta: 0.8, longitudeDelta: 0.8 }, 900
      );
    } else {
      const c = clients.find(c => c.status === 'active') ?? clients[0];
      if (c) mapRef.current?.animateToRegion(
        { latitude: c.mapLat, longitude: c.mapLng, latitudeDelta: 0.8, longitudeDelta: 0.8 }, 900
      );
    }
  };

  // ── Historial de ruta ──
  const clearRoute = () => { routeRef.current = null; setRoute(null); };

  const toggleRoute = async (grp: GroupRow) => {
    if (routeRef.current?.groupId === grp.group_id) { clearRoute(); return; }
    const { data, error } = await supabase.rpc('get_group_route', {
      p_group_id: grp.group_id, p_hours: 12,
    });
    if (error) { console.warn('[AdminMap] get_group_route:', error.message); return; }
    const pts = ((data as any[]) ?? [])
      .filter(r => typeof r.lat === 'number' && typeof r.lng === 'number')
      .map(r => ({ latitude: r.lat as number, longitude: r.lng as number }));
    if (pts.length < 2) {
      console.warn(`[AdminMap] get_group_route(${grp.group_name}): solo ${pts.length} puntos — sin recorrido suficiente`);
      return;
    }
    // Conectar la cabeza de la ruta con el marcador en vivo: el último punto del
    // historial puede tener hasta 5 min — sin esto la polyline termina "atrás"
    // del grupo hasta el siguiente update Realtime.
    const last = pts[pts.length - 1];
    if (Math.abs(last.latitude - grp.mapLat) > 1e-6 || Math.abs(last.longitude - grp.mapLng) > 1e-6) {
      pts.push({ latitude: grp.mapLat, longitude: grp.mapLng });
    }
    const next: RouteState = {
      groupId: grp.group_id, name: grp.group_name,
      color: STATUS[grp.status].color, points: pts,
    };
    routeRef.current = next;
    setRoute(next);
    mapRef.current?.fitToCoordinates(pts, {
      edgePadding: { top: 200, right: 70, bottom: 160, left: 70 }, animated: true,
    });
  };

  // Segmentos con degradado de opacidad: cola tenue (origen) → cabeza sólida (actual)
  const routeSegments = useMemo(() => {
    if (!route || route.points.length < 2) return [];
    const SEGS = Math.min(12, route.points.length - 1);
    const per  = (route.points.length - 1) / SEGS;
    const out: { pts: { latitude: number; longitude: number }[]; color: string }[] = [];
    for (let i = 0; i < SEGS; i++) {
      const a = Math.round(i * per);
      const b = Math.round((i + 1) * per);
      const alpha = 0.15 + 0.80 * (i / Math.max(SEGS - 1, 1));
      const hex = Math.round(alpha * 255).toString(16).padStart(2, '0');
      out.push({ pts: route.points.slice(a, b + 1), color: `${route.color}${hex}` });
    }
    return out;
  }, [route]);

  // Puntos de dirección: crecen y se opacan hacia la posición actual
  const routeDots = useMemo(() => {
    if (!route) return [];
    const step = Math.max(1, Math.floor(route.points.length / 14));
    const sampled = route.points.filter((_, i) => i % step === 0);
    return sampled.map((p, i) => ({ ...p, t: i / Math.max(sampled.length - 1, 1) }));
  }, [route]);

  // Connections derived
  const connectionMap = useMemo(() => {
    const m = new Map<string, ConnectionRow>();
    for (const c of connections) m.set(c.group.id, c);
    return m;
  }, [connections]);

  const connectionRegime: 'full' | 'medium' | 'lite' | 'minimal' =
    connections.length <= 8  ? 'full'    :
    connections.length <= 15 ? 'medium'  :
    connections.length <= 25 ? 'lite'    : 'minimal';

  // ── Filtros ──
  const matchCity = (city: string | null) =>
    !cityFilter || (city ?? '').toLowerCase().trim() === cityFilter.toLowerCase().trim();

  const filteredGroups = useMemo(() => groups.filter(g => {
    if (!matchCity(g.city)) return false;
    if (!statusFilter) return true;
    if (statusFilter === 'gps') return g.hasGps;
    return g.status === statusFilter;
  }), [groups, statusFilter, cityFilter]);

  const filteredTalents = useMemo(() => talents.filter(t => {
    if (!matchCity(t.city)) return false;
    if (!statusFilter) return true;
    if (statusFilter === 'gps') return t.hasGps;
    if (statusFilter === 'offline') return t.availability !== 'available';
    return t.availability === 'available'; // in_event/active → disponible
  }), [talents, statusFilter, cityFilter]);

  const filteredClients = useMemo(() => clients.filter(c => {
    if (!matchCity(c.city)) return false;
    if (!statusFilter) return true;
    if (statusFilter === 'gps') return true; // clientes siempre llegan con GPS
    if (statusFilter === 'offline') return c.status !== 'active';
    return c.status === 'active';
  }), [clients, statusFilter, cityFilter]);

  // Ciudades únicas para el modal de filtro (según modo activo)
  const cityOptions = useMemo(() => {
    const src = mode === 'groups' ? groups.map(g => g.city)
      : mode === 'talents' ? talents.map(t => t.city)
      : clients.map(c => c.city);
    const seen = new Map<string, string>();
    for (const c of src) {
      if (!c) continue;
      const k = c.toLowerCase().trim();
      if (!seen.has(k)) seen.set(k, c.trim());
    }
    return [...seen.values()].sort((a, b) => a.localeCompare(b));
  }, [mode, groups, talents, clients]);

  // ── Clusters por modo (celdas según zoom) ──
  const groupClusters = useMemo(() => {
    if (mode !== 'groups') return [];
    const pri: Record<GroupStatus, number> = { in_event: 2, active: 1, offline: 0 };
    return clusterize(filteredGroups.map(g => ({
      id: g.group_id, lat: g.mapLat, lng: g.mapLng,
      statusColor: STATUS[g.status].color, statusPriority: pri[g.status],
    })), latDelta);
  }, [mode, filteredGroups, latDelta]);

  const talentClusters = useMemo(() => {
    if (mode !== 'talents') return [];
    return clusterize(filteredTalents.map(t => ({
      id: t.talent_id, lat: t.mapLat, lng: t.mapLng,
      statusColor: t.availability === 'available' ? TALENT_COLOR : '#777',
      statusPriority: t.availability === 'available' ? 1 : 0,
    })), latDelta);
  }, [mode, filteredTalents, latDelta]);

  const clientClusters = useMemo(() => {
    if (mode !== 'clients') return [];
    return clusterize(filteredClients.map(c => ({
      id: c.client_id, lat: c.mapLat, lng: c.mapLng,
      statusColor: c.status === 'active' ? CLIENT_COLOR : '#666',
      statusPriority: c.status === 'active' ? 1 : 0,
    })), latDelta);
  }, [mode, filteredClients, latDelta]);

  const groupById  = useMemo(() => new Map(filteredGroups.map(g => [g.group_id, g])), [filteredGroups]);
  const talentById = useMemo(() => new Map(filteredTalents.map(t => [t.talent_id, t])), [filteredTalents]);
  const clientById = useMemo(() => new Map(filteredClients.map(c => [c.client_id, c])), [filteredClients]);

  const expandCluster = (cl: Cluster) => {
    mapRef.current?.animateToRegion({
      latitude: cl.lat, longitude: cl.lng,
      latitudeDelta: Math.max(latDelta / 3.2, 0.05),
      longitudeDelta: Math.max(region.longitudeDelta / 3.2, 0.05),
    }, 450);
  };

  // ── Filas visibles en el viewport actual (bottom sheet) ──
  const sheetRows: SheetRow[] = useMemo(() => {
    const halfLat = region.latitudeDelta / 2;
    const halfLng = region.longitudeDelta / 2;
    const inView = (lat: number, lng: number) =>
      Math.abs(lat - region.latitude) <= halfLat && Math.abs(lng - region.longitude) <= halfLng;
    const dist = (lat: number, lng: number) => haversineKm(region.latitude, region.longitude, lat, lng);

    let rows: SheetRow[];
    if (mode === 'groups') {
      rows = filteredGroups.filter(g => inView(g.mapLat, g.mapLng)).map(g => ({
        id: g.group_id, name: g.group_name, image: g.profile_image,
        city: g.city, statusColor: STATUS[g.status].color, statusLabel: STATUS[g.status].label,
        hasGps: g.hasGps, lat: g.mapLat, lng: g.mapLng, distKm: dist(g.mapLat, g.mapLng),
      }));
    } else if (mode === 'talents') {
      rows = filteredTalents.filter(t => inView(t.mapLat, t.mapLng)).map(t => ({
        id: t.talent_id, name: t.full_name, image: t.avatar_url,
        city: t.city,
        statusColor: t.availability === 'available' ? TALENT_COLOR : '#777',
        statusLabel: t.availability === 'available' ? 'Disponible' : t.availability === 'busy' ? 'Ocupado' : 'No disponible',
        hasGps: t.hasGps, lat: t.mapLat, lng: t.mapLng, distKm: dist(t.mapLat, t.mapLng),
      }));
    } else {
      rows = filteredClients.filter(c => inView(c.mapLat, c.mapLng)).map(c => ({
        id: c.client_id, name: c.full_name, image: c.avatar_url,
        city: c.city,
        statusColor: c.status === 'active' ? CLIENT_COLOR : '#666',
        statusLabel: c.status === 'active' ? 'En la app' : 'Offline',
        hasGps: true, lat: c.mapLat, lng: c.mapLng, distKm: dist(c.mapLat, c.mapLng),
      }));
    }
    return rows.sort((a, b) => a.distKm - b.distKm);
  }, [mode, filteredGroups, filteredTalents, filteredClients, region]);

  const focusRow = (row: SheetRow) => {
    snapSheet(false);
    mapRef.current?.animateToRegion(
      { latitude: row.lat, longitude: row.lng, latitudeDelta: 0.5, longitudeDelta: 0.5 }, 700
    );
  };

  const toggleStatusFilter = (f: Exclude<StatusFilter, null>) =>
    setStatusFilter(prev => (prev === f ? null : f));

  // Groups stats
  const evCnt   = groups.filter(g => g.status === 'in_event').length;
  const appCnt  = groups.filter(g => g.status === 'active').length;
  const offCnt  = groups.filter(g => g.status === 'offline').length;
  const gpsCnt  = groups.filter(g => g.hasGps).length;
  // Talent stats
  const availCnt  = talents.filter(t => t.availability === 'available').length;
  const busyCnt   = talents.filter(t => t.availability === 'busy').length;
  const gpsLiveCnt = talents.filter(t => t.hasGps).length;
  // Client stats
  const clientActCnt = clients.filter(c => c.status === 'active').length;
  const clientOffCnt = clients.filter(c => c.status === 'offline').length;

  const hasActiveFilter = !!statusFilter || !!cityFilter;
  const modeAccent = mode === 'groups' ? COLORS.green : mode === 'talents' ? TALENT_COLOR : CLIENT_COLOR;
  const sheetNoun  = mode === 'groups' ? 'grupos' : mode === 'talents' ? 'talentos' : 'clientes';

  const renderGroupMarker = (grp: GroupRow) => {
    const conn = connectionMap.get(grp.group_id);
    // Ruta solo con GPS real + reserva activa — los aproximados por ciudad no tienen recorrido.
    // in_event cuenta como reserva activa aunque la conexión no exista (p.ej. el
    // cliente cerró la app y su GPS quedó stale — la tocada sigue en curso).
    const canRoute     = grp.hasGps &&
      (ROUTE_REQUIRES_ACTIVE_BOOKING ? (!!conn || grp.status === 'in_event') : true);
    const routeVisible = route?.groupId === grp.group_id;
    return (
      <Marker
        key={`${grp.group_id}-${sizeKey}`}
        coordinate={{ latitude: grp.mapLat, longitude: grp.mapLng }}
        tracksViewChanges={grp.status === 'in_event' && tier === 'full'}
        anchor={{ x: 0.5, y: 0.5 }}
      >
        <GroupMarker
          status={grp.status}
          profileImage={grp.profile_image}
          name={grp.group_name}
          hasGps={grp.hasGps}
          tier={tier}
          eventStatus={conn?.eventStatus ?? null}
          bookingType={conn?.bookingType ?? null}
        />
        {tier !== 'dot' && (
          // onPress del Callout — los botones internos no reciben touches en Android
          <Callout tooltip onPress={() => { if (canRoute) toggleRoute(grp); }}>
            <View style={s.callout}>
              <Text style={s.calloutName}>{grp.group_name}</Text>
              <Text style={[s.calloutSub, { color: STATUS[grp.status].color }]}>
                {STATUS[grp.status].label}{grp.city ? ` · ${grp.city}` : ''}
              </Text>
              {grp.last_seen && <Text style={s.calloutTime}>{timeAgo(grp.last_seen)}</Text>}
              {canRoute ? (
                <View style={[s.calloutRouteBtn, { borderColor: `${STATUS[grp.status].color}55` }]}>
                  <Text style={[s.calloutRouteTxt, { color: STATUS[grp.status].color }]}>
                    {routeVisible ? '✕ Ocultar ruta' : '⤳ Ver ruta'}
                  </Text>
                </View>
              ) : (
                // Sin GPS real no hay recorrido que mostrar — decirlo evita confusión
                <Text style={[s.calloutTime, { marginTop: 4 }]}>
                  {!grp.hasGps ? '≈ ubicación aproximada' : 'sin reserva activa'}
                </Text>
              )}
            </View>
          </Callout>
        )}
      </Marker>
    );
  };

  const renderTalentMarker = (t: TalentRow) => (
    <Marker
      key={`${t.talent_id}-${sizeKey}`}
      coordinate={{ latitude: t.mapLat, longitude: t.mapLng }}
      tracksViewChanges={false}
      anchor={{ x: 0.5, y: 0.5 }}
    >
      <TalentMarker
        avatarUrl={t.avatar_url}
        name={t.full_name}
        availability={t.availability}
        hasGps={t.hasGps}
        tier={tier}
      />
      {tier !== 'dot' && (
        <Callout tooltip>
          <View style={s.callout}>
            <Text style={s.calloutName}>{t.full_name}</Text>
            <Text style={[s.calloutSub, { color: '#7C4DFF' }]}>
              {t.instrument}{t.city ? ` · ${t.city}` : ''}
            </Text>
            <Text style={[s.calloutTime, { color: t.availability === 'available' ? '#4CAF50' : '#999' }]}>
              {t.availability === 'available' ? 'Disponible' : t.availability === 'busy' ? 'Ocupado' : 'No disponible'}
            </Text>
          </View>
        </Callout>
      )}
    </Marker>
  );

  const renderClientMarker = (c: ClientRow) => (
    <Marker
      key={`${c.client_id}-${sizeKey}`}
      coordinate={{ latitude: c.mapLat, longitude: c.mapLng }}
      tracksViewChanges={false}
      anchor={{ x: 0.5, y: 0.5 }}
    >
      <ClientMarker
        avatarUrl={c.avatar_url}
        name={c.full_name}
        status={c.status}
        tier={tier}
      />
      {tier !== 'dot' && (
        <Callout tooltip>
          <View style={s.callout}>
            <Text style={s.calloutName}>{c.full_name}</Text>
            <Text style={[s.calloutSub, { color: CLIENT_COLOR }]}>
              Cliente{c.city ? ` · ${c.city}` : ''}{c.state ? `, ${c.state}` : ''}
            </Text>
            <Text style={[s.calloutTime, { color: c.status === 'active' ? '#4CAF50' : '#999' }]}>
              {c.status === 'active' ? 'En la app' : 'Offline'}
            </Text>
          </View>
        </Callout>
      )}
    </Marker>
  );

  return (
    <View style={s.root}>

      {/* ── MAPA FULL-BLEED ── */}
      <MapView
        ref={mapRef}
        style={StyleSheet.absoluteFillObject}
        provider={Platform.OS === 'android' ? PROVIDER_GOOGLE : undefined}
        customMapStyle={EARTH_STYLE}
        userInterfaceStyle="dark"
        initialRegion={{ latitude: 23.5, longitude: -102.5, latitudeDelta: 26, longitudeDelta: 26 }}
        mapPadding={{ top: insets.top + 150, right: 0, bottom: insets.bottom + 16, left: 0 }}
        scrollEnabled={true}
        zoomEnabled={true}
        rotateEnabled={true}
        pitchEnabled={false}
        showsUserLocation={false}
        showsMyLocationButton={false}
        showsPointsOfInterest={false}
        showsBuildings={false}
        showsCompass={false}
        showsIndoors={false}
        toolbarEnabled={false}
        moveOnMarkerPress={false}
        onRegionChangeComplete={handleRegionChange}
      >
        {/* Connection arcs + client destination markers — groups mode only */}
        {mode === 'groups' && connections.map(conn => {
          const hasBothCoords =
            conn.group.lat && conn.group.lng && conn.client.lat && conn.client.lng;
          if (!hasBothCoords) return null;
          return (
            <React.Fragment key={conn.reservationId}>
              <EventArc connection={conn} regime={connectionRegime} />
              {/* ClientConnectionMarker solo cuando hay arco visible (no en minimal) */}
              {connectionRegime !== 'minimal' && (
                <Marker
                  coordinate={{ latitude: conn.client.lat, longitude: conn.client.lng }}
                  tracksViewChanges={false}
                  anchor={{ x: 0.5, y: 0.5 }}
                >
                  <ClientConnectionMarker
                    avatarUrl={conn.client.avatar}
                    name={conn.client.name}
                    eventStatus={conn.eventStatus}
                    bookingType={conn.bookingType}
                    tier={tier}
                  />
                </Marker>
              )}
            </React.Fragment>
          );
        })}

        {/* Historial de ruta — degradado de opacidad: origen tenue → posición actual sólida */}
        {mode === 'groups' && route && (
          <>
            {routeSegments.map((seg, i) => (
              <Polyline
                key={`rt-${route.groupId}-${i}`}
                coordinates={seg.pts}
                strokeWidth={3.5}
                strokeColor={seg.color}
              />
            ))}
            {routeDots.map((d, i) => (
              <Marker
                key={`rtd-${route.groupId}-${i}`}
                coordinate={{ latitude: d.latitude, longitude: d.longitude }}
                anchor={{ x: 0.5, y: 0.5 }}
                tracksViewChanges={false}
              >
                <View style={{
                  width: 5 + 5 * d.t, height: 5 + 5 * d.t,
                  borderRadius: (5 + 5 * d.t) / 2,
                  backgroundColor: route.color,
                  opacity: 0.3 + 0.65 * d.t,
                  // El origen lleva borde blanco para distinguir "de dónde viene"
                  borderWidth: i === 0 ? 1.5 : 0, borderColor: '#fff',
                }} />
              </Marker>
            ))}
          </>
        )}

        {/* Marcadores con clustering: ≥2 en la misma celda → burbuja con número */}
        {mode === 'groups' && groupClusters.map(cl => {
          if (cl.ids.length > 1) {
            return (
              <Marker
                key={`cl-${cl.key}-${cl.ids.length}-${sizeKey}`}
                coordinate={{ latitude: cl.lat, longitude: cl.lng }}
                tracksViewChanges={false}
                anchor={{ x: 0.5, y: 0.5 }}
                onPress={() => expandCluster(cl)}
              >
                <ClusterBubble count={cl.ids.length} color={cl.color} tier={tier} />
              </Marker>
            );
          }
          const grp = groupById.get(cl.ids[0]);
          return grp ? renderGroupMarker(grp) : null;
        })}

        {mode === 'talents' && talentClusters.map(cl => {
          if (cl.ids.length > 1) {
            return (
              <Marker
                key={`cl-${cl.key}-${cl.ids.length}-${sizeKey}`}
                coordinate={{ latitude: cl.lat, longitude: cl.lng }}
                tracksViewChanges={false}
                anchor={{ x: 0.5, y: 0.5 }}
                onPress={() => expandCluster(cl)}
              >
                <ClusterBubble count={cl.ids.length} color={cl.color} tier={tier} />
              </Marker>
            );
          }
          const t = talentById.get(cl.ids[0]);
          return t ? renderTalentMarker(t) : null;
        })}

        {mode === 'clients' && clientClusters.map(cl => {
          if (cl.ids.length > 1) {
            return (
              <Marker
                key={`cl-${cl.key}-${cl.ids.length}-${sizeKey}`}
                coordinate={{ latitude: cl.lat, longitude: cl.lng }}
                tracksViewChanges={false}
                anchor={{ x: 0.5, y: 0.5 }}
                onPress={() => expandCluster(cl)}
              >
                <ClusterBubble count={cl.ids.length} color={cl.color} tier={tier} />
              </Marker>
            );
          }
          const c = clientById.get(cl.ids[0]);
          return c ? renderClientMarker(c) : null;
        })}
      </MapView>

      {/* ── PROFUNDIDAD: viñeta radial + scrims para legibilidad ── */}
      <MapVignette />
      <LinearGradient
        colors={['rgba(2,7,16,0.94)', 'rgba(2,7,16,0.5)', 'transparent']}
        style={[s.topScrim, { height: insets.top + 165 }]}
        pointerEvents="none"
      />
      <LinearGradient
        colors={['transparent', 'rgba(2,7,16,0.5)']}
        style={s.bottomScrim}
        pointerEvents="none"
      />

      {/* ── HEADER FLOTANTE ── */}
      <View style={[s.header, { top: insets.top + 6 }]}>
        <Pressable style={s.iconBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <View style={s.headerMid}>
          <View style={{ alignItems: 'center' }}>
            <Text style={s.brand}>DARICEFY</Text>
            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
              <Text style={s.title}>Mapa en vivo</Text>
              <View style={s.liveChip}>
                <LivePulse />
                <Text style={s.liveText}>LIVE</Text>
              </View>
            </View>
          </View>
        </View>
        <View style={{ flexDirection: 'row', gap: 8 }}>
          <Pressable style={s.iconBtn} onPress={() => setFilterOpen(true)}>
            <SlidersHorizontal size={16} color={hasActiveFilter ? modeAccent : COLORS.muted2} />
            {hasActiveFilter && <View style={[s.filterDot, { backgroundColor: modeAccent }]} />}
          </Pressable>
          <Pressable style={s.iconBtn} onPress={() => {
            if (mode === 'groups') { fetchAll(); fetchConnections(); }
            else if (mode === 'talents') fetchTalents();
            else fetchClients();
          }}>
            <RefreshCw size={16} color={COLORS.muted2} />
          </Pressable>
        </View>
      </View>

      {/* ── MODE TOGGLE FLOTANTE ── */}
      <View style={[s.modeToggleRow, { top: insets.top + 64 }]}>
        <Pressable
          style={[s.modeBtn, mode === 'groups' && s.modeBtnActive]}
          onPress={() => handleModeSwitch('groups')}
        >
          <Users size={12} color={mode === 'groups' ? COLORS.bg : COLORS.muted2} />
          <Text style={[s.modeBtnTxt, mode === 'groups' && s.modeBtnTxtActive]}>Grupos</Text>
        </Pressable>
        <Pressable
          style={[s.modeBtn, mode === 'talents' && { backgroundColor: TALENT_COLOR, borderColor: TALENT_COLOR }]}
          onPress={() => handleModeSwitch('talents')}
        >
          <Music size={12} color={mode === 'talents' ? '#fff' : COLORS.muted2} />
          <Text style={[s.modeBtnTxt, mode === 'talents' && { color: '#fff' }]}>Talentos</Text>
        </Pressable>
        <Pressable
          style={[s.modeBtn, mode === 'clients' && { backgroundColor: CLIENT_COLOR, borderColor: CLIENT_COLOR }]}
          onPress={() => handleModeSwitch('clients')}
        >
          <Radio size={12} color={mode === 'clients' ? '#fff' : COLORS.muted2} />
          <Text style={[s.modeBtnTxt, mode === 'clients' && { color: '#fff' }]}>Clientes</Text>
        </Pressable>
      </View>

      {/* ── CHIPS DE STATS FLOTANTES (tappables → filtran) ── */}
      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        style={[s.chipsRow, { top: insets.top + 108 }]}
        contentContainerStyle={s.chipsContent}
      >
        {mode === 'groups' ? (
          <>
            <StatChip
              icon={<Zap size={13} color={COLORS.green} />}
              label="Tocando" count={evCnt} color={COLORS.green} prominent
              active={statusFilter === 'in_event'} onPress={() => toggleStatusFilter('in_event')}
            />
            <StatChip
              icon={<Wifi size={12} color="#4CAF50" />}
              label="En app" count={appCnt} color="#4CAF50"
              active={statusFilter === 'active'} onPress={() => toggleStatusFilter('active')}
            />
            <StatChip
              icon={<Radio size={12} color={GPS_BLUE} />}
              label="GPS real" count={gpsCnt} color={GPS_BLUE}
              active={statusFilter === 'gps'} onPress={() => toggleStatusFilter('gps')}
            />
            <StatChip
              icon={<WifiOff size={12} color="#777" />}
              label="Offline" count={offCnt} color="#777"
              active={statusFilter === 'offline'} onPress={() => toggleStatusFilter('offline')}
            />
          </>
        ) : mode === 'talents' ? (
          <>
            <StatChip
              icon={<Zap size={13} color={TALENT_COLOR} />}
              label="Disponible" count={availCnt} color={TALENT_COLOR} prominent
              active={statusFilter === 'active' || statusFilter === 'in_event'}
              onPress={() => toggleStatusFilter('active')}
            />
            <StatChip
              icon={<Radio size={12} color={GPS_BLUE} />}
              label="GPS vivo" count={gpsLiveCnt} color={GPS_BLUE}
              active={statusFilter === 'gps'} onPress={() => toggleStatusFilter('gps')}
            />
            <StatChip
              icon={<WifiOff size={12} color="#777" />}
              label="Ocupado" count={busyCnt} color="#777"
              active={statusFilter === 'offline'} onPress={() => toggleStatusFilter('offline')}
            />
          </>
        ) : (
          <>
            <StatChip
              icon={<Zap size={13} color={CLIENT_COLOR} />}
              label="En app" count={clientActCnt} color={CLIENT_COLOR} prominent
              active={statusFilter === 'active' || statusFilter === 'in_event'}
              onPress={() => toggleStatusFilter('active')}
            />
            <StatChip
              icon={<Radio size={12} color={GPS_BLUE} />}
              label="GPS vivo" count={clients.length} color={GPS_BLUE}
              active={statusFilter === 'gps'} onPress={() => toggleStatusFilter('gps')}
            />
            <StatChip
              icon={<WifiOff size={12} color="#777" />}
              label="Offline" count={clientOffCnt} color="#777"
              active={statusFilter === 'offline'} onPress={() => toggleStatusFilter('offline')}
            />
          </>
        )}
      </ScrollView>

      {/* ── EMPTY STATE FLOTANTE ── */}
      {mode === 'talents' && talents.length === 0 && !loading && (
        <View style={s.emptyHint} pointerEvents="none">
          <Text style={s.emptyHintTxt}>Sin talentos con ubicación activa</Text>
          <Text style={[s.emptyHintTxt, { fontSize: 10, opacity: 0.5, marginTop: 2 }]}>
            Aparecerán aquí cuando abran la app
          </Text>
        </View>
      )}
      {mode === 'clients' && clients.length === 0 && !loading && (
        <View style={s.emptyHint} pointerEvents="none">
          <Text style={s.emptyHintTxt}>Sin clientes con ubicación activa</Text>
          <Text style={[s.emptyHintTxt, { fontSize: 10, opacity: 0.5, marginTop: 2 }]}>
            Aparecerán aquí cuando abran la app
          </Text>
        </View>
      )}

      {/* ── INTRO SALTABLE — tap en cualquier parte salta el vuelo de cámara ── */}
      {introActive && (
        <Pressable style={s.introSkip} onPress={skipIntro}>
          <View style={s.introSkipHint}>
            <Text style={s.introSkipTxt}>Toca para saltar</Text>
          </View>
        </Pressable>
      )}

      {/* ── FABs — esquina inferior derecha: lista de grupos en vista + ir al activo ── */}
      <Pressable
        style={[s.fab, { bottom: insets.bottom + 16 + 64, borderColor: COLORS.border }]}
        onPress={() => snapSheet(true)}
      >
        <List size={20} color={COLORS.muted2} />
        {/* Badge de conteo — se actualiza con el viewport */}
        {sheetRows.length > 0 && (
          <View style={[s.fabBadge, { backgroundColor: modeAccent }]}>
            <Text style={s.fabBadgeTxt}>{sheetRows.length > 99 ? '99+' : sheetRows.length}</Text>
          </View>
        )}
      </Pressable>
      {((mode === 'groups' && groups.some(g => g.status !== 'offline')) ||
        (mode === 'talents' && talents.length > 0) ||
        (mode === 'clients' && clients.length > 0)) && (
        <Pressable
          style={[s.fab, { bottom: insets.bottom + 16, borderColor: `${modeAccent}66` }]}
          onPress={flyToActive}
        >
          <Crosshair size={22} color={modeAccent} />
        </Pressable>
      )}

      {/* ── PÍLDORA "OCULTAR RUTA" — visible mientras hay ruta dibujada ── */}
      {mode === 'groups' && route && (
        <View
          style={[s.routePillWrap, { bottom: insets.bottom + 24 }]}
          pointerEvents="box-none"
        >
          <Pressable
            style={[s.routePill, { borderColor: `${route.color}66` }]}
            onPress={clearRoute}
          >
            <View style={[s.sheetStatusDot, { backgroundColor: route.color }]} />
            <Text style={s.routePillTxt} numberOfLines={1}>Ruta · {route.name}</Text>
            <X size={14} color={COLORS.muted2} />
          </Pressable>
        </View>
      )}

      {/* ── BOTTOM SHEET DESLIZABLE ── */}
      <Animated.View style={[
        s.sheet,
        { height: SHEET_H, paddingBottom: insets.bottom, transform: [{ translateY: sheetY }] },
      ]}>
        {/* Zona de agarre — el PanResponder vive aquí para no pelear con el scroll de la lista */}
        <View {...panResponder.panHandlers}>
          <View style={s.sheetHandle} />
          <View style={s.sheetPeekRow}>
            <Text style={s.sheetPeekTxt}>
              {sheetRows.length} {sheetNoun} en vista
            </Text>
            {mode === 'groups' && connections.length > 0 && (
              <View style={s.sheetEventBadge}>
                <Text style={s.sheetEventBadgeTxt}>
                  {connections.length} {connections.length === 1 ? 'evento vivo' : 'eventos vivos'}
                </Text>
              </View>
            )}
            <Pressable
              style={s.sheetClose}
              hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
              onPress={() => snapSheet(false)}
            >
              <X size={16} color={COLORS.muted2} />
            </Pressable>
          </View>
        </View>

        <FlatList
          data={sheetRows}
          keyExtractor={r => r.id}
          scrollEnabled={sheetOpen}
          showsVerticalScrollIndicator={false}
          contentContainerStyle={{ paddingHorizontal: SPACING.xl, paddingBottom: 20 }}
          ListEmptyComponent={
            <Text style={s.sheetEmpty}>Nada en esta zona del mapa</Text>
          }
          renderItem={({ item }) => (
            <Pressable style={s.sheetItem} onPress={() => focusRow(item)}>
              <View style={[s.sheetAvatar, { borderColor: item.statusColor }]}>
                {item.image
                  ? <Image source={{ uri: item.image }} style={{ width: '100%', height: '100%' }} resizeMode="cover" />
                  : (
                    <View style={s.sheetAvatarFallback}>
                      <Text style={{ color: item.statusColor, fontFamily: FONTS.title, fontSize: 15 }}>
                        {item.name.trim()[0]?.toUpperCase() ?? '?'}
                      </Text>
                    </View>
                  )
                }
              </View>
              <View style={{ flex: 1 }}>
                <Text style={s.sheetItemName} numberOfLines={1}>{item.name}</Text>
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 2 }}>
                  <View style={[s.sheetStatusDot, { backgroundColor: item.statusColor }]} />
                  <Text style={[s.sheetItemSub, { color: item.statusColor }]}>{item.statusLabel}</Text>
                  {item.city && <Text style={s.sheetItemSub} numberOfLines={1}>· {item.city}</Text>}
                  {item.hasGps && <Text style={[s.sheetItemSub, { color: GPS_BLUE }]}>· GPS</Text>}
                </View>
              </View>
              <Text style={s.sheetItemDist}>{formatDist(item.distKm)}</Text>
            </Pressable>
          )}
        />
      </Animated.View>

      {/* ── MODAL DE FILTROS ── */}
      <Modal visible={filterOpen} transparent animationType="fade" onRequestClose={() => setFilterOpen(false)}>
        <Pressable style={s.modalBackdrop} onPress={() => setFilterOpen(false)}>
          <Pressable style={[s.modalCard, { paddingBottom: insets.bottom + 16 }]} onPress={() => {}}>
            <View style={s.modalHeader}>
              <Text style={s.modalTitle}>Filtros</Text>
              <Pressable style={s.iconBtn} onPress={() => setFilterOpen(false)}>
                <X size={16} color={COLORS.muted2} />
              </Pressable>
            </View>

            <Text style={s.modalSection}>Estado</Text>
            <View style={s.modalOptRow}>
              {([
                { key: null,        label: 'Todos',    color: COLORS.text },
                { key: 'in_event',  label: 'Tocando',  color: COLORS.green },
                { key: 'active',    label: 'En app',   color: '#4CAF50' },
                { key: 'offline',   label: 'Offline',  color: '#777' },
                { key: 'gps',       label: 'GPS real', color: GPS_BLUE },
              ] as { key: StatusFilter; label: string; color: string }[]).map(opt => {
                const active = statusFilter === opt.key;
                return (
                  <Pressable
                    key={opt.label}
                    style={[s.modalOpt, active && { backgroundColor: `${opt.color}22`, borderColor: opt.color }]}
                    onPress={() => setStatusFilter(opt.key)}
                  >
                    <Text style={[s.modalOptTxt, active && { color: opt.color }]}>{opt.label}</Text>
                  </Pressable>
                );
              })}
            </View>

            <Text style={s.modalSection}>Ciudad</Text>
            <ScrollView style={{ maxHeight: 220 }} showsVerticalScrollIndicator={false}>
              <View style={s.modalOptRow}>
                <Pressable
                  style={[s.modalOpt, !cityFilter && { backgroundColor: `${modeAccent}22`, borderColor: modeAccent }]}
                  onPress={() => setCityFilter(null)}
                >
                  <Text style={[s.modalOptTxt, !cityFilter && { color: modeAccent }]}>Todas</Text>
                </Pressable>
                {cityOptions.map(c => {
                  const active = cityFilter?.toLowerCase().trim() === c.toLowerCase().trim();
                  return (
                    <Pressable
                      key={c}
                      style={[s.modalOpt, active && { backgroundColor: `${modeAccent}22`, borderColor: modeAccent }]}
                      onPress={() => setCityFilter(active ? null : c)}
                    >
                      <Text style={[s.modalOptTxt, active && { color: modeAccent }]}>{c}</Text>
                    </Pressable>
                  );
                })}
              </View>
            </ScrollView>

            {hasActiveFilter && (
              <Pressable
                style={s.modalClear}
                onPress={() => { setStatusFilter(null); setCityFilter(null); }}
              >
                <Text style={s.modalClearTxt}>Limpiar filtros</Text>
              </Pressable>
            )}
          </Pressable>
        </Pressable>
      </Modal>

    </View>
  );
}

// ─── Styles ───────────────────────────────────────────────────────────────────

const OVERLAY_BG = 'rgba(8,12,24,0.88)';

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#020812' },

  topScrim: {
    position: 'absolute', top: 0, left: 0, right: 0,
    zIndex: 5,
  },
  bottomScrim: {
    position: 'absolute', bottom: 0, left: 0, right: 0,
    height: 110, zIndex: 5,
  },

  header: {
    position: 'absolute', left: SPACING.xl, right: SPACING.xl,
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    zIndex: 10,
  },
  iconBtn: {
    width: 36, height: 36, borderRadius: RADIUS.md,
    backgroundColor: OVERLAY_BG, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  filterDot: {
    position: 'absolute', top: 6, right: 6,
    width: 7, height: 7, borderRadius: 3.5,
  },
  headerMid: { flexDirection: 'row', alignItems: 'center' },
  brand: {
    fontFamily: FONTS.title, fontSize: 9, letterSpacing: 5,
    color: `${COLORS.green}CC`, marginBottom: 1,
  },
  title: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  liveChip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: OVERLAY_BG, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: `${COLORS.green}35`,
    paddingHorizontal: 8, paddingVertical: 3,
  },
  liveText: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.green, letterSpacing: 0.8 },

  modeToggleRow: {
    position: 'absolute', left: 0, right: 0,
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 8, zIndex: 10,
  },
  modeBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 18, paddingVertical: 8,
    borderRadius: RADIUS.full, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: OVERLAY_BG,
  },
  modeBtnActive: {
    backgroundColor: COLORS.green, borderColor: COLORS.green,
  },
  modeBtnTxt: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  modeBtnTxtActive: { color: COLORS.bg },

  chipsRow: {
    position: 'absolute', left: 0, right: 0,
    maxHeight: 52, zIndex: 10,
  },
  chipsContent: {
    paddingHorizontal: SPACING.xl, gap: 8, alignItems: 'center',
  },
  chip: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    backgroundColor: OVERLAY_BG,
    borderRadius: RADIUS.full, borderWidth: 1,
    paddingHorizontal: 12, paddingVertical: 7,
  },
  chipProminent: {
    paddingHorizontal: 16, paddingVertical: 10,
  },
  chipN: { fontFamily: FONTS.title, fontSize: 13 },
  chipL: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, letterSpacing: 0.3 },

  fab: {
    position: 'absolute', right: SPACING.xl,
    width: 52, height: 52, borderRadius: 26,
    backgroundColor: OVERLAY_BG, borderWidth: 1.5,
    alignItems: 'center', justifyContent: 'center',
    zIndex: 11,
    shadowColor: '#000', shadowOpacity: 0.4, shadowRadius: 8, shadowOffset: { width: 0, height: 3 },
    elevation: 6,
  },
  fabBadge: {
    position: 'absolute', top: -5, right: -5,
    minWidth: 21, height: 21, borderRadius: 10.5,
    paddingHorizontal: 5,
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 2, borderColor: '#020812',
  },
  fabBadgeTxt: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: '#041007' },

  introSkip: {
    ...StyleSheet.absoluteFillObject,
    zIndex: 20,
    justifyContent: 'flex-end', alignItems: 'center',
  },
  introSkipHint: {
    marginBottom: 120,
    backgroundColor: OVERLAY_BG, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 7,
  },
  introSkipTxt: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },

  sheet: {
    position: 'absolute', left: 0, right: 0, bottom: 0,
    backgroundColor: 'rgba(8,12,24,0.96)',
    borderTopLeftRadius: 22, borderTopRightRadius: 22,
    borderWidth: 1, borderBottomWidth: 0, borderColor: COLORS.border,
    zIndex: 12,
  },
  sheetHandle: {
    alignSelf: 'center', marginTop: 7,
    width: 40, height: 4, borderRadius: 2,
    backgroundColor: 'rgba(255,255,255,0.25)',
  },
  sheetPeekRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 10, paddingVertical: 8,
  },
  sheetPeekTxt: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.text },
  sheetClose: {
    position: 'absolute', right: 14, top: 2,
    width: 30, height: 30, borderRadius: 15,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  sheetEventBadge: {
    backgroundColor: `${COLORS.green}18`, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: `${COLORS.green}40`,
    paddingHorizontal: 10, paddingVertical: 3,
  },
  sheetEventBadgeTxt: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.green },
  sheetEmpty: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2,
    textAlign: 'center', marginTop: 24,
  },
  sheetItem: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    paddingVertical: 10,
    borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: COLORS.border,
  },
  sheetAvatar: {
    width: 42, height: 42, borderRadius: 21,
    borderWidth: 2, overflow: 'hidden', backgroundColor: '#13151c',
  },
  sheetAvatarFallback: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  sheetStatusDot: { width: 7, height: 7, borderRadius: 3.5 },
  sheetItemName: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  sheetItemSub:  { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2, flexShrink: 1 },
  sheetItemDist: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted2 },

  emptyHint: {
    position: 'absolute', alignSelf: 'center', top: '45%',
    alignItems: 'center',
    backgroundColor: OVERLAY_BG, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 18, paddingVertical: 8,
    zIndex: 9,
  },
  emptyHintTxt: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, textAlign: 'center' },

  routePillWrap: {
    position: 'absolute', left: 0, right: 0,
    alignItems: 'center', zIndex: 11,
  },
  routePill: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: OVERLAY_BG,
    borderRadius: RADIUS.full, borderWidth: 1,
    paddingHorizontal: 14, paddingVertical: 8,
    maxWidth: '78%',
  },
  routePillTxt: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.text, flexShrink: 1 },

  callout: {
    backgroundColor: '#0d0d0d', borderRadius: 10,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 8,
    alignItems: 'center', minWidth: 120,
  },
  calloutRouteBtn: {
    marginTop: 6, borderRadius: RADIUS.full, borderWidth: 1,
    paddingHorizontal: 10, paddingVertical: 4,
  },
  calloutRouteTxt: { fontFamily: FONTS.bodySemiBold, fontSize: 11 },
  calloutName: { color: COLORS.text, fontFamily: FONTS.bodySemiBold, fontSize: 13 },
  calloutSub:  { fontFamily: FONTS.bodyMedium, fontSize: 11, marginTop: 2 },
  calloutTime: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted2, marginTop: 2 },

  modalBackdrop: {
    flex: 1, backgroundColor: 'rgba(0,0,0,0.6)', justifyContent: 'flex-end',
  },
  modalCard: {
    backgroundColor: '#0c1120',
    borderTopLeftRadius: 22, borderTopRightRadius: 22,
    borderWidth: 1, borderBottomWidth: 0, borderColor: COLORS.border,
    paddingHorizontal: SPACING.xl, paddingTop: 16,
  },
  modalHeader: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    marginBottom: 6,
  },
  modalTitle: { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text },
  modalSection: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.muted2,
    letterSpacing: 0.8, textTransform: 'uppercase', marginTop: 14, marginBottom: 8,
  },
  modalOptRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  modalOpt: {
    borderRadius: RADIUS.full, borderWidth: 1, borderColor: COLORS.border,
    backgroundColor: COLORS.card, paddingHorizontal: 14, paddingVertical: 7,
  },
  modalOptTxt: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  modalClear: {
    alignSelf: 'center', marginTop: 16,
    paddingHorizontal: 18, paddingVertical: 8,
    borderRadius: RADIUS.full, borderWidth: 1, borderColor: '#FF525255',
  },
  modalClearTxt: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#FF8A80' },
});
