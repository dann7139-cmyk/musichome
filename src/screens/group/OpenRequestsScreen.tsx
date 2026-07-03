/**
 * OpenRequestsScreen — Panel de Solicitudes Abiertas (grupo)
 *
 * Muestra solicitudes de clientes que coinciden con el género del grupo.
 * El primer grupo en aceptar se queda con el evento.
 *
 * MAPA: muestra la zona aproximada (radio ~2 km sobre el centro de la ciudad).
 *       La dirección exacta solo se revela después de que el cliente pague.
 */
import {
  ArrowLeft,
  Calendar,
  Clock,
  Map,
  MapPin,
  Users,
  X,
  Zap,
} from 'lucide-react-native';
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Animated,
  Dimensions,
  Image,
  Linking,
  Modal,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import * as Location from 'expo-location';
import MapView, { Circle, Marker, Polyline, PROVIDER_GOOGLE } from 'react-native-maps';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { parseEventDateMX } from '../../utils/calculations';
import { EARTH_STYLE } from '../../constants/mapStyle';

const { height: SH } = Dimensions.get('window');

// ─── Coordenadas de ciudades (para mostrar zona aproximada) ──────────────────
const CITY_COORDS: Record<string, { lat: number; lng: number }> = {
  'zapopan':            { lat: 20.7167, lng: -103.3833 },
  'guadalajara':        { lat: 20.6597, lng: -103.3496 },
  'tlaquepaque':        { lat: 20.6419, lng: -103.3117 },
  'tonalá':             { lat: 20.6236, lng: -103.2347 },
  'tonala':             { lat: 20.6236, lng: -103.2347 },
  'puerto vallarta':    { lat: 20.6534, lng: -105.2253 },
  'ciudad de méxico':   { lat: 19.4326, lng: -99.1332 },
  'ciudad de mexico':   { lat: 19.4326, lng: -99.1332 },
  'cdmx':               { lat: 19.4326, lng: -99.1332 },
  'ecatepec':           { lat: 19.6012, lng: -99.0599 },
  'monterrey':          { lat: 25.6866, lng: -100.3161 },
  'san nicolás':        { lat: 25.7464, lng: -100.2976 },
  'puebla':             { lat: 19.0414, lng: -98.2063 },
  'tijuana':            { lat: 32.5149, lng: -117.0382 },
  'mexicali':           { lat: 32.6245, lng: -115.4523 },
  'león':               { lat: 21.1221, lng: -101.6826 },
  'leon':               { lat: 21.1221, lng: -101.6826 },
  'guanajuato':         { lat: 21.0190, lng: -101.2574 },
  'chihuahua':          { lat: 28.6330, lng: -106.0691 },
  'ciudad juárez':      { lat: 31.6904, lng: -106.4245 },
  'torreón':            { lat: 25.5428, lng: -103.4068 },
  'torreon':            { lat: 25.5428, lng: -103.4068 },
  'aguascalientes':     { lat: 21.8818, lng: -102.2916 },
  'san luis potosí':    { lat: 22.1565, lng: -100.9855 },
  'san luis potosi':    { lat: 22.1565, lng: -100.9855 },
  'mérida':             { lat: 20.9674, lng: -89.5926 },
  'merida':             { lat: 20.9674, lng: -89.5926 },
  'cancún':             { lat: 21.1619, lng: -86.8515 },
  'cancun':             { lat: 21.1619, lng: -86.8515 },
  'veracruz':           { lat: 19.1738, lng: -96.1342 },
  'querétaro':          { lat: 20.5888, lng: -100.3899 },
  'queretaro':          { lat: 20.5888, lng: -100.3899 },
  'culiacán':           { lat: 24.8091, lng: -107.3940 },
  'culiacan':           { lat: 24.8091, lng: -107.3940 },
  'hermosillo':         { lat: 29.0729, lng: -110.9559 },
  'acapulco':           { lat: 16.8531, lng: -99.8237 },
  'saltillo':           { lat: 25.4270, lng: -101.0034 },
  'morelia':            { lat: 19.7060, lng: -101.1950 },
  'oaxaca':             { lat: 17.0732, lng: -96.7266 },
  'durango':            { lat: 24.0277, lng: -104.6532 },
  'tepic':              { lat: 21.5051, lng: -104.8954 },
  'zacatecas':          { lat: 22.7709, lng: -102.5832 },
  'toluca':             { lat: 19.2826, lng: -99.6557 },
  'cuernavaca':         { lat: 18.9261, lng: -99.2305 },
  'mazatlán':           { lat: 23.2494, lng: -106.4111 },
  'mazatlan':           { lat: 23.2494, lng: -106.4111 },
  'los mochis':         { lat: 25.7900, lng: -108.9860 },
  'irapuato':           { lat: 20.6735, lng: -101.3548 },
  'celaya':             { lat: 20.5234, lng: -100.8119 },
};

function idHash(id: string): number {
  let h = 5381;
  for (let i = 0; i < id.length; i++) h = ((h << 5) + h + id.charCodeAt(i)) | 0;
  return Math.abs(h);
}

function getCityCoords(city: string, id: string, municipio?: string | null): { lat: number; lng: number } {
  // Intentar municipio primero (más preciso), luego ciudad
  const candidates = [municipio, city].filter(Boolean) as string[];
  for (const name of candidates) {
    const key = name.toLowerCase().trim();
    const base = CITY_COORDS[key]
      ?? Object.entries(CITY_COORDS).find(([k]) => key.includes(k) || k.includes(key))?.[1];
    if (base) {
      // Offset determinístico ±1.5 km para que cada solicitud se vea en un punto distinto
      const h = idHash(id);
      return {
        lat: base.lat + ((h % 300) - 150) / 10000,
        lng: base.lng + (((h * 31) % 300) - 150) / 10000,
      };
    }
  }
  // Fallback determinístico dentro de México
  const h = idHash(id);
  return {
    lat: 20 + (h % 8000) / 1000,
    lng: -104 + ((h * 79) % 14000) / 1000,
  };
}

// ─── Estilo oscuro del mapa — unificado en src/constants/mapStyle.ts ──────────
const DARK_MAP_STYLE = EARTH_STYLE;

// ─── Tipos ────────────────────────────────────────────────────────────────────
interface EventRequest {
  id: string;
  genre: string;
  event_type: string;
  event_date: string;
  event_time: string | null;
  hours: number;
  guest_count: number | null;
  location_city: string;
  location_municipio: string | null;
  location_estado: string;
  venue_covered: string | null;
  venue_size: string | null;
  needs_sound: string | null;
  comments: string | null;
  status: string;
  created_at: string;
  expires_at: string;
  negotiating_group_id: string | null;
  notified_count: number | null;
  current_wave: number | null;
  accepted_reservation: { address: string | null; payment_status: string | null } | null;
}

const EVENT_TYPE_LABELS: Record<string, string> = {
  fiesta_privada: '🎉 Fiesta privada',
  boda:           '💍 Boda',
  cumpleanos:     '🎂 Cumpleaños',
  graduacion:     '🎓 Graduación',
  empresarial:    '🏢 Empresarial',
  otro:           '🎵 Otro',
};

const VENUE_COVERED_LABELS: Record<string, string> = {
  si:    '✅ Techado',
  no:    '☀️ Al aire libre',
  no_se: '❓ No sé',
};

function timeUntilExpiry(expiresAt: string): string {
  const diff = new Date(expiresAt).getTime() - Date.now();
  if (diff <= 0) return 'Expirada';
  const hours = Math.floor(diff / 3_600_000);
  const mins  = Math.floor((diff % 3_600_000) / 60_000);
  const secs  = Math.floor((diff % 60_000) / 1_000);
  if (hours > 0) return `${hours}h ${mins}min restantes`;
  if (mins > 0)  return `${mins}m ${String(secs).padStart(2, '0')}s`;
  return `${secs}s`;
}

function formatDate(d: string): string {
  return new Date(d + 'T12:00:00').toLocaleDateString('es-MX', {
    weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
  });
}

function formatTime12h(t: string): string {
  const [hStr, mStr] = t.split(':');
  const h = parseInt(hStr, 10);
  return `${h % 12 || 12}:${mStr} ${h >= 12 ? 'PM' : 'AM'}`;
}

// ─── Seeded random (determinístico por request ID) ───────────────────────────
function seededRand(seed: string, idx: number): number {
  let h = 0xdeadbeef;
  const s = seed + '|' + idx;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 0x9e3779b9);
  h ^= h >>> 16;
  return (h >>> 0) / 0xffffffff;
}

// Emojis que viajan por la ruta hacia la zona
const ROUTE_NOTES = ['🎵', '🎶', '🎸', '🎺'];

// Punto en el borde del círculo (radio dado) en dirección al grupo
function calcCircleBoundaryPoint(
  groupLoc: { latitude: number; longitude: number },
  center: { lat: number; lng: number },
  radiusMeters: number,
): { latitude: number; longitude: number } {
  const dLat = groupLoc.latitude - center.lat;
  const dLng = groupLoc.longitude - center.lng;
  const dist = Math.sqrt(dLat * dLat + dLng * dLng);
  if (dist === 0) return { latitude: center.lat + 0.013, longitude: center.lng };
  const radiusDeg = radiusMeters / 111320;
  const cosLat = Math.cos((center.lat * Math.PI) / 180);
  return {
    latitude:  center.lat + (dLat / dist) * radiusDeg,
    longitude: center.lng + (dLng / dist) * (radiusDeg / (cosLat || 1)),
  };
}

// Posición fallback del grupo ~4-6 km del centro (cuando no hay GPS)
function computeFallbackGroupLoc(
  center: { lat: number; lng: number },
  requestId: string,
): { latitude: number; longitude: number } {
  const angle   = seededRand(requestId, 99) * 2 * Math.PI;
  const distDeg = 0.036 + seededRand(requestId, 100) * 0.018;
  return {
    latitude:  center.lat + Math.sin(angle) * distDeg,
    longitude: center.lng + Math.cos(angle) * distDeg,
  };
}

// Waypoints con ligeras curvas perpendiculares para simular calles
function computeRouteWaypoints(
  from: { latitude: number; longitude: number },
  to:   { latitude: number; longitude: number },
  requestId: string,
): { latitude: number; longitude: number }[] {
  const dLat = to.latitude  - from.latitude;
  const dLng = to.longitude - from.longitude;
  const perpSign  = seededRand(requestId, 77) > 0.5 ? 1 : -1;
  const perpScale = 0.005 * perpSign;
  const perpNorm  = Math.sqrt(dLat * dLat + dLng * dLng) || 1;
  return [
    from,
    {
      latitude:  from.latitude  + dLat * 0.35 + (-dLng / perpNorm) * perpScale,
      longitude: from.longitude + dLng * 0.35 + ( dLat / perpNorm) * perpScale,
    },
    {
      latitude:  from.latitude  + dLat * 0.68 + (-dLng / perpNorm) * perpScale * -0.6,
      longitude: from.longitude + dLng * 0.68 + ( dLat / perpNorm) * perpScale * -0.6,
    },
    to,
  ];
}

// Interpola coordenadas a lo largo de los waypoints (t: 0→1)
function lerpAlongRoute(
  waypoints: { latitude: number; longitude: number }[],
  t: number,
): { latitude: number; longitude: number } {
  const segCount = waypoints.length - 1;
  const scaled   = t * segCount;
  const segIdx   = Math.min(Math.floor(scaled), segCount - 1);
  const segT     = scaled - segIdx;
  const a = waypoints[segIdx];
  const b = waypoints[segIdx + 1];
  return {
    latitude:  a.latitude  + (b.latitude  - a.latitude)  * segT,
    longitude: a.longitude + (b.longitude - a.longitude) * segT,
  };
}

// ─── Componente: Modal con mapa de zona aproximada ───────────────────────────
function ZoneMapModal({
  request,
  onClose,
}: {
  request: EventRequest | null;
  onClose: () => void;
}) {
  const scaleAnims = useRef(
    Array.from({ length: 4 }, () => new Animated.Value(1.0))
  ).current;

  const [groupLoc,      setGroupLoc]      = useState<{ latitude: number; longitude: number } | null>(null);
  const [emojiPositions, setEmojiPositions] = useState<{ latitude: number; longitude: number }[]>([]);
  const progressRef  = useRef<number[]>([0, 0.25, 0.5, 0.75]);
  const intervalRef  = useRef<ReturnType<typeof setInterval> | null>(null);
  const waypointsRef = useRef<{ latitude: number; longitude: number }[]>([]);

  useEffect(() => {
    if (!request) return;

    const center = getCityCoords(request.location_city, request.id, request.location_municipio);

    // Obtener ubicación real del dispositivo o usar fallback
    (async () => {
      let loc: { latitude: number; longitude: number } | null = null;
      try {
        const { status } = await Location.requestForegroundPermissionsAsync();
        if (status === 'granted') {
          const pos = await Location.getCurrentPositionAsync({
            accuracy: Location.Accuracy.Balanced,
          });
          loc = { latitude: pos.coords.latitude, longitude: pos.coords.longitude };
        }
      } catch {
        // Silencioso — simulador / sin permiso
      }
      if (!loc) loc = computeFallbackGroupLoc(center, request.id);
      setGroupLoc(loc);

      const lineEnd  = calcCircleBoundaryPoint(loc, center, 1500);
      const waypoints = computeRouteWaypoints(loc, lineEnd, request.id);
      waypointsRef.current = waypoints;

      progressRef.current = [0, 0.25, 0.5, 0.75];
      setEmojiPositions(progressRef.current.map(t => lerpAlongRoute(waypoints, t)));

      // Mover emojis a lo largo de la ruta
      intervalRef.current = setInterval(() => {
        progressRef.current = progressRef.current.map(p => (p + 0.005) % 1);
        setEmojiPositions(
          progressRef.current.map(t => lerpAlongRoute(waypointsRef.current, t))
        );
      }, 50);
    })();

    // Pulso/explosión para cada emoji
    scaleAnims.forEach((anim, i) => {
      Animated.loop(
        Animated.sequence([
          Animated.delay(i * 250),
          Animated.timing(anim, { toValue: 1.9, duration: 300, useNativeDriver: true }),
          Animated.timing(anim, { toValue: 1.0, duration: 300, useNativeDriver: true }),
          Animated.delay(700),
        ])
      ).start();
    });

    return () => {
      scaleAnims.forEach(a => a.stopAnimation());
      if (intervalRef.current) clearInterval(intervalRef.current);
      intervalRef.current = null;
    };
  }, [request?.id]);

  if (!request) return null;

  const res              = request.accepted_reservation;
  const isPaid           = res?.payment_status === 'paid' || res?.payment_status === 'deposit_paid' || res?.payment_status === 'fully_paid';
  const exactAddress     = isPaid ? (res?.address ?? null) : null;

  const center           = getCityCoords(request.location_city, request.id, request.location_municipio);
  const effectiveGroup   = groupLoc ?? computeFallbackGroupLoc(center, request.id);
  const lineEnd          = calcCircleBoundaryPoint(effectiveGroup, center, 1500);
  const routeWaypoints   = waypointsRef.current.length > 0
    ? waypointsRef.current
    : computeRouteWaypoints(effectiveGroup, lineEnd, request.id);

  const initialRegion = {
    latitude:       center.lat,
    longitude:      center.lng,
    latitudeDelta:  0.038,
    longitudeDelta: 0.038,
  };

  return (
    <Modal visible={!!request} transparent animationType="slide" onRequestClose={onClose}>
      <View style={ms.overlay}>
        <View style={ms.sheet}>
          {/* Header */}
          <View style={ms.header}>
            <View style={{ flex: 1 }}>
              <Text style={ms.title}>{isPaid ? '📍 Ubicación exacta' : '📍 Zona del evento'}</Text>
              <Text style={ms.sub}>
                {request.location_city}, {request.location_estado}
                {!isPaid && (
                  <>
                    {'  ·  '}
                    <Text style={{ color: COLORS.muted }}>Zona aproximada</Text>
                  </>
                )}
              </Text>
            </View>
            <Pressable style={ms.closeBtn} onPress={onClose}>
              <X size={18} color={COLORS.text} />
            </Pressable>
          </View>

          {/* Mapa */}
          <View style={ms.mapWrap}>
            <MapView
              provider={PROVIDER_GOOGLE}
              style={ms.map}
              initialRegion={initialRegion}
              customMapStyle={DARK_MAP_STYLE}
              scrollEnabled={true}
              zoomEnabled={true}
              pitchEnabled={false}
              rotateEnabled={false}
              showsUserLocation={true}
              showsMyLocationButton={false}
              toolbarEnabled={false}
            >
              {/* ── Círculos concéntricos (efecto ripple) ───────────────── */}
              <Circle
                center={{ latitude: center.lat, longitude: center.lng }}
                radius={2500}
                fillColor="rgba(0,230,118,0.05)"
                strokeColor="rgba(0,230,118,0.55)"
                strokeWidth={2}
              />
              <Circle
                center={{ latitude: center.lat, longitude: center.lng }}
                radius={1500}
                fillColor="rgba(0,230,118,0.08)"
                strokeColor="rgba(0,230,118,0.30)"
                strokeWidth={1.5}
              />
              <Circle
                center={{ latitude: center.lat, longitude: center.lng }}
                radius={700}
                fillColor="rgba(0,230,118,0.14)"
                strokeColor="rgba(0,230,118,0.12)"
                strokeWidth={1}
              />

              {/* ── Ruta desde la ubicación del grupo hasta el 2° círculo ── */}
              <Polyline
                coordinates={routeWaypoints}
                strokeColor="rgba(0,230,118,0.70)"
                strokeWidth={2.5}
                lineDashPattern={[10, 7]}
              />

              {/* ── Emojis musicales con explosión viajando por la ruta ─── */}
              {emojiPositions.map((coord, i) => (
                <Marker
                  key={`route-note-${i}`}
                  coordinate={coord}
                  anchor={{ x: 0.5, y: 0.5 }}
                  tracksViewChanges
                >
                  <Animated.View
                    style={[
                      ms.routeNoteWrap,
                      { transform: [{ scale: scaleAnims[i] }] },
                    ]}
                  >
                    <Text style={ms.routeNoteEmoji}>{ROUTE_NOTES[i]}</Text>
                  </Animated.View>
                </Marker>
              ))}
            </MapView>

            {/* Overlay: dirección exacta si está pagado, o aviso de zona si no */}
            {isPaid && exactAddress ? (
              <View style={ms.lockOverlay}>
                <View style={[ms.lockBadge, ms.paidBadge]}>
                  <Text style={ms.lockIcon}>📌</Text>
                  <Text style={[ms.lockText, { color: COLORS.text, flex: 1 }]} numberOfLines={3}>
                    {exactAddress}
                  </Text>
                  <Pressable
                    style={ms.mapsBtn}
                    onPress={() => {
                      const url = `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(exactAddress)}`;
                      Linking.openURL(url);
                    }}
                  >
                    <Text style={ms.mapsBtnText}>Abrir →</Text>
                  </Pressable>
                </View>
              </View>
            ) : (
              <View style={ms.lockOverlay}>
                <View style={ms.lockBadge}>
                  <Text style={ms.lockIcon}>🔒</Text>
                  <Text style={ms.lockText}>
                    Zona aproximada ~2 km · La ubicación exacta{'\n'}
                    se revela cuando el cliente complete el pago
                  </Text>
                </View>
              </View>
            )}
          </View>

          {/* Info del evento */}
          <View style={ms.infoGrid}>
            <View style={ms.infoItem}>
              <Calendar size={14} color={COLORS.muted2} />
              <Text style={ms.infoText}>{formatDate(request.event_date)}</Text>
            </View>
            <View style={ms.infoItem}>
              <Clock size={14} color={COLORS.muted2} />
              <Text style={ms.infoText}>{request.hours}h · {request.event_time ? formatTime12h(request.event_time) : 'hora a confirmar'}</Text>
            </View>
            {request.guest_count && (
              <View style={ms.infoItem}>
                <Users size={14} color={COLORS.muted2} />
                <Text style={ms.infoText}>~{request.guest_count} personas</Text>
              </View>
            )}
          </View>

          <Pressable style={ms.closeFullBtn} onPress={onClose}>
            <Text style={ms.closeFullBtnText}>Cerrar mapa</Text>
          </Pressable>
        </View>
      </View>
    </Modal>
  );
}

// ─── Componente: Card pulsante para solicitudes nuevas ───────────────────────
function PulsingCard({ children, style }: { children: React.ReactNode; style?: any }) {
  const pulse = useRef(new Animated.Value(1)).current;
  useEffect(() => {
    const anim = Animated.loop(
      Animated.sequence([
        Animated.timing(pulse, { toValue: 1.015, duration: 900, useNativeDriver: true }),
        Animated.timing(pulse, { toValue: 1,     duration: 900, useNativeDriver: true }),
      ])
    );
    anim.start();
    return () => anim.stop();
  }, []);
  return (
    <Animated.View style={[style, { transform: [{ scale: pulse }] }]}>
      {children}
    </Animated.View>
  );
}

// ─── Screen principal ─────────────────────────────────────────────────────────
export default function OpenRequestsScreen({ navigation, route }: any) {
  const highlightId = (route?.params?.requestId as string | undefined) ?? null;

  const [requests,       setRequests]       = useState<EventRequest[]>([]);
  const [myProposalIds,  setMyProposalIds]  = useState<Set<string>>(new Set());
  const [acceptedCount,  setAcceptedCount]  = useState(0);
  const [groupGenre,     setGroupGenre]     = useState<string | null>(null);
  const [currentUid,     setCurrentUid]     = useState<string | null>(null);
  const [loading,        setLoading]        = useState(true);
  const [refreshing,     setRefreshing]     = useState(false);
  const [mapRequest,     setMapRequest]     = useState<EventRequest | null>(null);
  const [, setTick]                         = useState(0);

  // Tick cada segundo para actualizar los badges de tiempo restante
  useEffect(() => {
    const id = setInterval(() => setTick(t => t + 1), 1_000);
    return () => clearInterval(id);
  }, []);

  const fetchData = async () => {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;
    setCurrentUid(user.id);

    const { data: grp } = await supabase
      .from('groups')
      .select('id, genre')
      .eq('owner_id', user.id)
      .single();

    setGroupGenre(grp?.genre ?? null);
    if (!grp?.genre) { setLoading(false); return; }

    // Traer solicitudes 'open' Y 'en_negociacion' del mismo género
    const [{ data }, { count }, { data: myPropsData }] = await Promise.all([
      supabase
        .from('event_requests')
        .select('*, requester:profiles!client_id(full_name, avatar_url, role), accepted_reservation:reservations!accepted_reservation_id(address, payment_status)')
        .in('status', ['open', 'en_negociacion'])
        .eq('genre', grp.genre)
        .gt('expires_at', new Date().toISOString())
        .order('created_at', { ascending: false }),
      // Contar solicitudes que aceptó este grupo (tienen reserva pendiente de confirmar)
      supabase
        .from('event_requests')
        .select('id', { count: 'exact', head: true })
        .eq('status', 'accepted')
        .eq('accepted_by_group_id', grp.id),
      // Solicitudes donde ya envié propuesta
      supabase
        .from('event_request_proposals')
        .select('request_id')
        .eq('group_id', grp.id),
    ]);

    const { data: surgeData } = await supabase.rpc('get_surge_factor', { p_genre: grp.genre });
    const surgeFactor: number = (surgeData as any)?.surge_factor ?? 1;

    setMyProposalIds(new Set((myPropsData ?? []).map((p: any) => p.request_id)));
    setRequests(((data ?? []) as EventRequest[]).map(r => ({ ...r, demand_multiplier: surgeFactor })));
    setAcceptedCount(count ?? 0);
    setLoading(false);
  };

  const refresh = async () => { setRefreshing(true); await fetchData(); setRefreshing(false); };

  useEffect(() => { fetchData(); }, []);
  useFocusEffect(useCallback(() => { fetchData(); }, []));

  const handlePropose = (req: EventRequest) => {
    // Abre el formulario de cotización — el grupo llena precios antes de proponer
    navigation.navigate('ProposeRequest', { request: req });
  };

  if (loading) {
    return (
      <View style={s.center}>
        <ActivityIndicator color={COLORS.green} size="large" />
      </View>
    );
  }

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <View style={{ flex: 1 }}>
          <Text style={s.headerTitle}>Solicitudes disponibles</Text>
          {groupGenre && (
            <Text style={s.headerSub}>
              {groupGenre} · {requests.length} disponibles
            </Text>
          )}
        </View>
        <Zap size={20} color={COLORS.green} />
      </SafeAreaView>

      {!groupGenre && (
        <View style={s.emptyWrap}>
          <Text style={s.emptyEmoji}>🎸</Text>
          <Text style={s.emptyTitle}>Configura el género de tu grupo</Text>
          <Text style={s.emptySub}>
            Para ver solicitudes de clientes, configura el género musical en el perfil de tu grupo.
          </Text>
        </View>
      )}

      {groupGenre && (
        <ScrollView
          contentContainerStyle={s.scroll}
          showsVerticalScrollIndicator={false}
          refreshControl={<RefreshControl refreshing={refreshing} onRefresh={refresh} tintColor={COLORS.green} />}
        >
          {/* Banner: solicitudes aceptadas → ver reservas */}
          {acceptedCount > 0 && (
            <Pressable
              style={s.acceptedBanner}
              onPress={() => navigation.navigate('GroupReservations')}
            >
              <Text style={s.acceptedBannerText}>
                🎉 {acceptedCount} cliente{acceptedCount > 1 ? 's' : ''} aceptó tu propuesta → confirmar reserva
              </Text>
              <Text style={s.acceptedBannerArrow}>→</Text>
            </Pressable>
          )}

          {/* Info */}
          <View style={s.infoBanner}>
            <Text style={s.infoBannerText}>
              ⚡ Solicitudes de <Text style={{ fontFamily: FONTS.bodySemiBold, color: COLORS.green }}>{groupGenre}</Text>.
              Propón tu grupo → el cliente decide si te contrata.
              {'\n'}🔒 La dirección exacta se revela al confirmar el pago.
            </Text>
          </View>

          {requests.length === 0 && (
            <View style={s.emptyWrap}>
              <Text style={s.emptyEmoji}>🎵</Text>
              <Text style={s.emptyTitle}>Sin solicitudes por ahora</Text>
              <Text style={s.emptySub}>
                Cuando un cliente busque {groupGenre} su solicitud aparecerá aquí.
              </Text>
            </View>
          )}

          {/* Solicitud notificada primero, luego el resto por fecha */}
          {[...requests].sort((a, b) =>
            a.id === highlightId ? -1 : b.id === highlightId ? 1 : 0
          ).map(req => {
            const hoursLeft      = timeUntilExpiry(req.expires_at);
            const diffMs         = new Date(req.expires_at).getTime() - Date.now();
            const isUrgent       = diffMs > 0 && diffMs < 5 * 60_000;
            const isWarning      = diffMs >= 5 * 60_000 && diffMs < 10 * 60_000;
            const iAlreadyProposed = myProposalIds.has(req.id);
            const isHighlighted    = req.id === highlightId;

            // Evento urgente: comienza en menos de 6 horas
            const eventStart =
              parseEventDateMX(req.event_date, req.event_time ?? '20:00')?.getTime() ?? null;
            const isEventUrgent = eventStart !== null && eventStart - Date.now() < 6 * 3_600_000 && eventStart > Date.now();

            const viewers = req.notified_count ?? 0;
            const isNew   = Date.now() - new Date(req.created_at).getTime() < 10 * 60_000;

            const CardWrapper = isNew || isHighlighted ? PulsingCard : View;
            return (
              <CardWrapper key={req.id} style={[
                s.card,
                isHighlighted && s.cardHighlighted,
                isNew && !isHighlighted && s.cardNew,
              ]}>
                {isHighlighted && (
                  <View style={s.highlightBanner}>
                    <Text style={s.highlightBannerText}>📩 Solicitud que te notificó — revisa los detalles</Text>
                  </View>
                )}
                {/* Quién contrata */}
                {(() => {
                  const r = (req as any).requester;
                  if (!r) return null;
                  const typeLabel = r.role === 'group'
                    ? '🎸 Grupo'
                    : r.role === 'talent' ? '🎵 Músico independiente' : '👤 Cliente particular';
                  return (
                    <View style={s.requesterRow}>
                      {r.avatar_url
                        ? <Image source={{ uri: r.avatar_url }} style={s.requesterAvatar} />
                        : (
                          <View style={s.requesterAvatarPlaceholder}>
                            <Text style={s.requesterAvatarInitial}>
                              {(r.full_name ?? '?').charAt(0).toUpperCase()}
                            </Text>
                          </View>
                        )
                      }
                      <Text style={s.requesterTypeText}>{typeLabel}</Text>
                    </View>
                  );
                })()}
                {/* Header */}
                <View style={s.cardHeader}>
                  <View style={{ flex: 1, gap: 6 }}>
                    <Text style={s.cardEventType}>
                      {EVENT_TYPE_LABELS[req.event_type] ?? req.event_type}
                    </Text>
                    {isNew && (
                      <View style={s.newBadge}>
                        <Text style={s.newBadgeText}>🆕 NUEVO</Text>
                      </View>
                    )}
                    <View style={[
                      s.expiryBadge,
                      isWarning && s.expiryBadgeWarning,
                      isUrgent  && s.expiryBadgeUrgent,
                    ]}>
                      <Text style={[
                        s.expiryText,
                        isWarning && s.expiryTextWarning,
                        isUrgent  && s.expiryTextUrgent,
                      ]}>
                        ⏱ {hoursLeft}
                      </Text>
                    </View>
                    {isEventUrgent && (
                      <View style={s.urgentBadge}>
                        <Text style={s.urgentBadgeText}>🔥 Evento urgente</Text>
                      </View>
                    )}
                    {viewers > 1 && (
                      <View style={s.competitionBadge}>
                        <Text style={s.competitionBadgeText}>👀 {viewers} grupos lo ven</Text>
                      </View>
                    )}
                    {(req as any).demand_multiplier > 1 && (
                      <View style={s.surgeBadge}>
                        <Text style={s.surgeBadgeText}>✨ Tarifa protegida</Text>
                      </View>
                    )}
                  </View>
                  <View style={{ alignItems: 'flex-end', gap: 6 }}>
                    <View style={s.genreChip}>
                      <Text style={s.genreChipText}>🎵 {req.genre}</Text>
                    </View>
                    {iAlreadyProposed && (
                      <View style={s.myNegBadge}>
                        <Text style={s.myNegBadgeText}>📩 Tu propuesta enviada</Text>
                      </View>
                    )}
                  </View>
                </View>

                {/* Detalles */}
                <View style={s.details}>
                  <View style={s.detailRow}>
                    <Calendar size={14} color={COLORS.muted2} />
                    <Text style={s.detailText}>{formatDate(req.event_date)}</Text>
                  </View>
                  {req.event_time && (
                    <View style={s.detailRow}>
                      <Clock size={14} color={COLORS.muted2} />
                      <Text style={s.detailText}>{formatTime12h(req.event_time)}</Text>
                    </View>
                  )}
                  <View style={s.detailRow}>
                    <Clock size={14} color={COLORS.muted2} />
                    <Text style={s.detailText}>{req.hours} horas de servicio</Text>
                  </View>
                  {req.guest_count != null && (
                    <View style={s.detailRow}>
                      <Users size={14} color={COLORS.muted2} />
                      <Text style={s.detailText}>~{req.guest_count} personas</Text>
                    </View>
                  )}
                  <View style={s.detailRow}>
                    <MapPin size={14} color={COLORS.muted2} />
                    <Text style={s.detailText}>
                      {req.location_city}, {req.location_estado}
                      {'  '}
                      <Text style={s.hiddenTag}>🔒 dirección oculta</Text>
                    </Text>
                  </View>
                  {req.venue_covered && (
                    <View style={s.detailRow}>
                      <Text style={s.detailText}>{VENUE_COVERED_LABELS[req.venue_covered] ?? req.venue_covered}</Text>
                    </View>
                  )}
                </View>

                {req.comments && (
                  <View style={s.commentsBox}>
                    <Text style={s.commentsText}>💬 {req.comments}</Text>
                  </View>
                )}

                {/* Confirmación si ya envié propuesta */}
                {iAlreadyProposed && (
                  <View style={s.awaitingBanner}>
                    <Text style={s.awaitingText}>
                      ⏳ Tu propuesta está en revisión. El cliente decidirá pronto.
                    </Text>
                  </View>
                )}

                {/* Botones */}
                <View style={s.divider} />
                <View style={s.btnRow}>
                  <Pressable style={s.mapBtn} onPress={() => setMapRequest(req)}>
                    <Map size={16} color={COLORS.green} />
                    <Text style={s.mapBtnText}>Ver zona</Text>
                  </Pressable>

                  <Pressable
                    style={s.acceptBtn}
                    onPress={() => handlePropose(req)}
                  >
                    <Zap size={16} color={COLORS.bg} />
                    <Text style={s.acceptBtnText}>
                      {iAlreadyProposed ? 'ACTUALIZAR PROPUESTA →' : 'COTIZAR Y PROPONER →'}
                    </Text>
                  </Pressable>
                </View>

                <Text style={s.addressNote}>
                  🔒 Dirección exacta visible al confirmar pago
                </Text>
              </CardWrapper>
            );
          })}

          <View style={{ height: 40 }} />
        </ScrollView>
      )}

      {/* Modal mapa de zona aproximada */}
      <ZoneMapModal request={mapRequest} onClose={() => setMapRequest(null)} />
    </View>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  root:   { flex: 1, backgroundColor: COLORS.bg },
  center: { flex: 1, backgroundColor: COLORS.bg, alignItems: 'center', justifyContent: 'center' },

  header: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1 },

  scroll: { padding: SPACING.xl },

  acceptedBanner: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    backgroundColor: 'rgba(0,230,118,0.14)',
    borderWidth: 1, borderColor: COLORS.green,
    borderRadius: RADIUS.lg, padding: 14, marginBottom: 12,
  },
  acceptedBannerText:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green, flex: 1 },
  acceptedBannerArrow: { fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.green, marginLeft: 8 },

  infoBanner: {
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    borderRadius: RADIUS.lg, padding: 14, marginBottom: 20,
  },
  infoBannerText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.green, lineHeight: 20 },

  emptyWrap:  { alignItems: 'center', paddingVertical: 60, paddingHorizontal: 20 },
  emptyEmoji: { fontSize: 52, marginBottom: 16 },
  emptyTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, textAlign: 'center', marginBottom: 10 },
  emptySub:   { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center', lineHeight: 22 },

  card: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 16,
  },
  cardNew: {
    borderColor: 'rgba(0,230,118,0.50)',
    backgroundColor: 'rgba(0,230,118,0.03)',
  },
  cardHighlighted: {
    borderColor: 'rgba(99,102,241,0.60)',
    backgroundColor: 'rgba(99,102,241,0.05)',
    shadowColor: '#6366F1',
    shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.3,
    shadowRadius: 8,
    elevation: 6,
  },
  highlightBanner: {
    backgroundColor: 'rgba(99,102,241,0.15)',
    borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(99,102,241,0.35)',
    paddingHorizontal: 10, paddingVertical: 6,
    marginBottom: 10,
  },
  highlightBannerText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#818CF8' },
  newBadge: {
    alignSelf: 'flex-start' as const,
    backgroundColor: 'rgba(0,230,118,0.15)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.40)',
    paddingHorizontal: 8, paddingVertical: 3,
  },
  newBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.green },
  cardNegotiating: {
    borderColor: 'rgba(255,179,0,0.40)',
    backgroundColor: 'rgba(255,179,0,0.04)',
  },

  // Badges de negociación
  negBadge: {
    backgroundColor: 'rgba(255,179,0,0.15)', borderRadius: RADIUS.full,
    paddingHorizontal: 8, paddingVertical: 4,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.40)',
  },
  negBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: '#FFB300' },

  myNegBadge: {
    backgroundColor: 'rgba(0,230,118,0.15)', borderRadius: RADIUS.full,
    paddingHorizontal: 8, paddingVertical: 4,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.40)',
  },
  myNegBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },

  // Banners de estado de negociación
  standbyBanner: {
    backgroundColor: 'rgba(255,179,0,0.10)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(255,179,0,0.30)',
    padding: 10, marginBottom: 8,
  },
  standbyText: { fontFamily: FONTS.body, fontSize: 12, color: '#FFB300', lineHeight: 18 },

  awaitingBanner: {
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    padding: 10, marginBottom: 8,
  },
  awaitingText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.green, lineHeight: 18 },

  standbyBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(255,179,0,0.10)', borderRadius: RADIUS.lg, paddingVertical: 12,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.30)',
  },
  standbyBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#FFB300' },

  cardHeader: {
    flexDirection: 'row', justifyContent: 'space-between',
    alignItems: 'flex-start', marginBottom: 12,
  },
  cardEventType: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },
  genreChip: {
    backgroundColor: 'rgba(0,230,118,0.1)', borderRadius: RADIUS.full,
    paddingHorizontal: 10, paddingVertical: 4,
  },
  genreChipText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },

  expiryBadge: {
    alignSelf: 'flex-start',
    backgroundColor: COLORS.bg, borderRadius: RADIUS.full,
    paddingHorizontal: 10, paddingVertical: 4,
    borderWidth: 1, borderColor: COLORS.green,
  },
  expiryBadgeWarning: { backgroundColor: 'rgba(255,179,0,0.12)', borderColor: COLORS.orange },
  expiryBadgeUrgent:  { backgroundColor: 'rgba(255,82,82,0.15)', borderColor: '#FF5252' },
  expiryText:         { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },
  expiryTextWarning:  { color: COLORS.orange },
  expiryTextUrgent:   { color: '#FF5252' },

  urgentBadge: {
    alignSelf: 'flex-start',
    backgroundColor: 'rgba(255,60,0,0.15)', borderRadius: RADIUS.full,
    paddingHorizontal: 10, paddingVertical: 4,
    borderWidth: 1, borderColor: 'rgba(255,60,0,0.50)',
  },
  urgentBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: '#FF3C00' },

  competitionBadge: {
    alignSelf: 'flex-start',
    backgroundColor: 'rgba(66,133,244,0.12)', borderRadius: RADIUS.full,
    paddingHorizontal: 10, paddingVertical: 4,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.35)',
  },
  competitionBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.blue },

  surgeBadge: {
    alignSelf: 'flex-start',
    backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: RADIUS.full,
    paddingHorizontal: 10, paddingVertical: 4,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
  },
  surgeBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.green },

  details:   { gap: 8, marginBottom: 10 },
  detailRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  detailText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, flex: 1 },
  hiddenTag:  { fontFamily: FONTS.bodyMedium, fontSize: 11, color: COLORS.muted },

  commentsBox: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 10, marginBottom: 8,
  },
  commentsText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 19 },

  divider: { height: 1, backgroundColor: COLORS.border, marginVertical: 12 },

  btnRow: { flexDirection: 'row', gap: 10 },

  mapBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 6,
    flex: 0.42,
    backgroundColor: 'rgba(0,230,118,0.10)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.40)',
    borderRadius: RADIUS.lg, paddingVertical: 12,
  },
  mapBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },

  acceptBtn: {
    flex: 1,
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg, paddingVertical: 12,
  },
  acceptBtnDisabled: { opacity: 0.6 },
  acceptBtnText:     { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  addressNote: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted,
    textAlign: 'center', marginTop: 10,
  },

  suggestBox: {
    backgroundColor: 'rgba(0,230,118,0.05)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.20)',
    paddingHorizontal: 12, paddingTop: 8, marginBottom: 8,
  },
  suggestRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingVertical: 7, borderBottomWidth: 1, borderBottomColor: 'rgba(0,230,118,0.10)',
  },
  suggestLabel: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  suggestValue: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.text, textAlign: 'right', flex: 1, marginLeft: 10 },

  // Requester identity row
  requesterRow: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    marginBottom: 10, paddingBottom: 10,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  requesterAvatar: { width: 28, height: 28, borderRadius: 14 },
  requesterAvatarPlaceholder: {
    width: 28, height: 28, borderRadius: 14,
    backgroundColor: 'rgba(0,230,118,0.12)', alignItems: 'center', justifyContent: 'center',
  },
  requesterAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  requesterTypeText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
});

// ─── Styles del modal de mapa ────────────────────────────────────────────────
const ms = StyleSheet.create({
  overlay: {
    flex: 1, backgroundColor: 'rgba(0,0,0,0.75)',
    justifyContent: 'flex-end',
  },
  sheet: {
    backgroundColor: COLORS.card,
    borderTopLeftRadius: 24, borderTopRightRadius: 24,
    borderTopWidth: 1, borderTopColor: COLORS.border,
    paddingBottom: 32,
    overflow: 'hidden',
  },

  header: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    paddingHorizontal: SPACING.xl, paddingVertical: 16,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  title: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.text },
  sub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  closeBtn: {
    width: 36, height: 36, borderRadius: 10,
    backgroundColor: COLORS.bg, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },

  mapWrap: { height: SH * 0.46, position: 'relative' },
  map:     { flex: 1 },

  // Emojis musicales que viajan por la ruta hacia la zona
  routeNoteWrap: {
    alignItems: 'center', justifyContent: 'center',
    width: 28, height: 28,
  },
  routeNoteEmoji: { fontSize: 16 },

  // Aviso sobre la dirección
  lockOverlay: {
    position: 'absolute', bottom: 12, left: 12, right: 12,
    alignItems: 'center',
  },
  lockBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: 'rgba(0,0,0,0.80)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 10,
  },
  lockIcon: { fontSize: 18 },
  lockText: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2,
    lineHeight: 17, flex: 1,
  },

  // Info row
  infoGrid: {
    gap: 8, paddingHorizontal: SPACING.xl, paddingVertical: 14,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  infoItem: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  infoText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },

  // Cerrar
  closeFullBtn: {
    marginHorizontal: SPACING.xl, marginTop: 16,
    backgroundColor: COLORS.bg,
    borderWidth: 1, borderColor: COLORS.border,
    borderRadius: RADIUS.lg, paddingVertical: 13,
    alignItems: 'center',
  },
  closeFullBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },

  paidBadge: {
    backgroundColor: 'rgba(0,230,118,0.12)',
    borderColor: 'rgba(0,230,118,0.5)',
    flexDirection: 'row' as const,
    alignItems: 'center' as const,
    gap: 8,
    paddingRight: 8,
  },
  mapsBtn: {
    backgroundColor: COLORS.green,
    borderRadius: RADIUS.md,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  mapsBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.bg },
});
