import React, { useEffect, useRef, useState } from 'react';
import {
  Alert, Animated, Image, KeyboardAvoidingView, Platform, Pressable,
  ScrollView, StyleSheet, Text, TextInput, View,
} from 'react-native';
import MapView, { Circle as MapCircle, Marker, Polyline, PROVIDER_GOOGLE } from 'react-native-maps';
import * as Location from 'expo-location';
import {
  CheckCircle, Clock, DollarSign, MapPin, Scale, Truck, XCircle,
} from 'lucide-react-native';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { EARTH_STYLE } from '../../constants/mapStyle';
import { PHONE_WARNING } from '../../utils/phoneFilter';

// ── Helpers de mapa (privacidad + ruta) ──────────────────────────────────────
const _CITY_COORDS: Record<string, { lat: number; lng: number }> = {
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
  'hermosillo':       { lat: 29.0729, lng: -110.9559 },
  'chihuahua':        { lat: 28.6330, lng: -106.0691 },
  'oaxaca':           { lat: 17.0732, lng: -96.7266 },
  'morelia':          { lat: 19.7060, lng: -101.1950 },
  'saltillo':         { lat: 25.4270, lng: -101.0034 },
  'mazatlán':         { lat: 23.2494, lng: -106.4111 },
  'mazatlan':         { lat: 23.2494, lng: -106.4111 },
  'veracruz':         { lat: 19.1738, lng: -96.1342 },
  'culiacán':         { lat: 24.8091, lng: -107.3940 },
  'culiacan':         { lat: 24.8091, lng: -107.3940 },
};
function _idHash(id: string) {
  let h = 5381;
  for (let i = 0; i < id.length; i++) h = ((h << 5) + h + id.charCodeAt(i)) | 0;
  return Math.abs(h);
}
function _privacyOffset(id: string, city: string, municipio?: string | null) {
  const key = (municipio ?? city).toLowerCase().trim();
  const base = _CITY_COORDS[key] ??
    Object.entries(_CITY_COORDS).find(([k]) => key.includes(k) || k.includes(key))?.[1] ??
    { lat: 20.6597, lng: -103.3496 };
  const h = _idHash(id);
  return { latitude: base.lat + ((h % 800) - 400) / 100_000, longitude: base.lng + (((h * 31) % 800) - 400) / 100_000 };
}
function _buildRoute(o: { latitude: number; longitude: number }, d: { latitude: number; longitude: number }) {
  const pts = [];
  for (let i = 0; i <= 8; i++) {
    const t = i / 8;
    const lat = o.latitude + (d.latitude - o.latitude) * t;
    const lng = o.longitude + (d.longitude - o.longitude) * t;
    const c = Math.sin(t * Math.PI) * 0.0025;
    pts.push({ latitude: lat - (d.longitude - o.longitude) * c, longitude: lng + (d.latitude - o.latitude) * c });
  }
  return pts;
}
function _lerpRoute(route: { latitude: number; longitude: number }[], t: number) {
  const c = Math.max(0, Math.min(1, t));
  const idx = c * (route.length - 1);
  const lo = Math.floor(idx), hi = Math.min(route.length - 1, lo + 1);
  const f = idx - lo;
  return { latitude: route[lo].latitude + (route[hi].latitude - route[lo].latitude) * f,
           longitude: route[lo].longitude + (route[hi].longitude - route[lo].longitude) * f };
}

type LatLng = { latitude: number; longitude: number };

function _RouteParticle({ route, delay, emoji }: { route: LatLng[]; delay: number; emoji: string }) {
  const [pos, setPos] = useState(_lerpRoute(route, 0));
  const [started, setStarted] = useState(false);
  useEffect(() => {
    if (route.length < 2) return;
    let startMs: number | null = null;
    let lastUpd = 0;
    let fid: number;
    const beginAt = Date.now() + delay;
    const tick = () => {
      fid = requestAnimationFrame(tick);
      const now = Date.now();
      if (now < beginAt) return;
      if (startMs === null) { startMs = now; setStarted(true); }
      if (now - lastUpd < 120) return;
      lastUpd = now;
      setPos(_lerpRoute(route, ((now - startMs) % 4000) / 4000));
    };
    fid = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(fid);
  }, [route, delay]);
  if (!started) return null;
  return (
    <Marker coordinate={pos} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges>
      <Text style={qlMapSt.emoji}>{emoji}</Text>
    </Marker>
  );
}

function _DestPin() {
  const ring1 = useRef(new Animated.Value(1)).current;
  const ring2 = useRef(new Animated.Value(0.6)).current;
  const ring3 = useRef(new Animated.Value(0.3)).current;
  useEffect(() => {
    const p = (v: Animated.Value, dur: number, del: number) =>
      Animated.loop(Animated.sequence([
        Animated.delay(del),
        Animated.timing(v, { toValue: 1.9, duration: dur, useNativeDriver: true }),
        Animated.timing(v, { toValue: 1,   duration: dur, useNativeDriver: true }),
      ]));
    p(ring1, 1400, 0).start();
    p(ring2, 1400, 350).start();
    p(ring3, 1400, 700).start();
  }, []);
  return (
    <View style={qlMapSt.pinWrap}>
      <Animated.View style={[qlMapSt.pulse, { width: 80, height: 80, borderRadius: 40, opacity: 0.12, transform: [{ scale: ring1 }] }]} />
      <Animated.View style={[qlMapSt.pulse, { width: 52, height: 52, borderRadius: 26, opacity: 0.25, transform: [{ scale: ring2 }] }]} />
      <Animated.View style={[qlMapSt.pulse, { width: 28, height: 28, borderRadius: 14, opacity: 0.45, transform: [{ scale: ring3 }] }]} />
      <View style={qlMapSt.pinCenter} />
    </View>
  );
}

const qlMapSt = StyleSheet.create({
  pinWrap:   { width: 100, height: 100, alignItems: 'center', justifyContent: 'center' },
  pulse:     { position: 'absolute', backgroundColor: 'rgba(0,230,118,0.18)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)' },
  pinCenter: { width: 12, height: 12, borderRadius: 6, backgroundColor: '#00E676', shadowColor: '#00E676', shadowOffset: { width: 0, height: 0 }, shadowOpacity: 1, shadowRadius: 10, elevation: 8 },
  emoji:     { fontSize: 22, lineHeight: 26 },
  originDot: { width: 18, height: 18, borderRadius: 9, backgroundColor: 'rgba(255,255,255,0.15)', borderWidth: 2, borderColor: '#fff', alignItems: 'center', justifyContent: 'center' },
  originInner: { width: 7, height: 7, borderRadius: 4, backgroundColor: '#fff' },
});

// ── QuoteLocationMap ──────────────────────────────────────────────────────────
function QuoteLocationMap({ quoteId, eventLatitude, eventLongitude, eventMunicipio, eventEstado, onOpenMaps }: {
  quoteId: string; eventLatitude?: number | null; eventLongitude?: number | null;
  eventMunicipio?: string; eventEstado?: string; onOpenMaps?: () => void;
}) {
  const mapRef = useRef<MapView>(null);
  const [groupOrigin, setGroupOrigin] = useState<LatLng | null>(null);
  const [approxDest,  setApproxDest]  = useState<LatLng | null>(null);
  const [routePts,    setRoutePts]    = useState<LatLng[]>([]);

  useEffect(() => {
    // Prioridad: coordenadas REALES del pin del cliente (quotes.latitude/longitude,
    // con jitter de privacidad determinístico) → fallback por nombre de ciudad
    if (eventLatitude != null && eventLongitude != null) {
      let h = 0; const seed = quoteId;
      for (let i = 0; i < seed.length; i++) h = (h * 31 + seed.charCodeAt(i)) & 0x7fffffff;
      setApproxDest({
        latitude:  eventLatitude  + ((h % 800) - 400) / 200_000,
        longitude: eventLongitude + (((h * 31) % 800) - 400) / 200_000,
      });
      return;
    }
    const city = eventMunicipio ?? eventEstado ?? 'guadalajara';
    setApproxDest(_privacyOffset(quoteId, city, eventMunicipio));
  }, [quoteId, eventLatitude, eventLongitude, eventMunicipio, eventEstado]);

  useEffect(() => {
    Location.requestForegroundPermissionsAsync().then(({ status }) => {
      if (status !== 'granted') return;
      Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced })
        .then(loc => setGroupOrigin({ latitude: loc.coords.latitude, longitude: loc.coords.longitude }))
        .catch(() => {});
    });
  }, []);

  useEffect(() => {
    if (!approxDest) return;
    const origin = groupOrigin ?? { latitude: approxDest.latitude + 0.015, longitude: approxDest.longitude + 0.01 };
    const pts = _buildRoute(origin, approxDest);
    setRoutePts(pts);
    setTimeout(() => {
      mapRef.current?.fitToCoordinates([origin, approxDest], {
        edgePadding: { top: 40, right: 40, bottom: 40, left: 40 }, animated: true,
      });
    }, 600);
  }, [approxDest, groupOrigin]);

  if (!approxDest) return null;

  return (
    <View>
      <View style={{ borderRadius: RADIUS.lg, overflow: 'hidden', marginBottom: 8 }}>
      <MapView
        ref={mapRef}
        style={qlMapSt2.map}
        provider={PROVIDER_GOOGLE}
        customMapStyle={EARTH_STYLE}
        userInterfaceStyle="dark"
        initialRegion={{ latitude: approxDest.latitude, longitude: approxDest.longitude, latitudeDelta: 0.018, longitudeDelta: 0.018 }}
        scrollEnabled={false}
        zoomEnabled={false}
        pitchEnabled={false}
        rotateEnabled={false}
        showsTraffic={false}
        showsBuildings={false}
        showsIndoors={false}
        showsCompass={false}
        showsMyLocationButton={false}
        showsUserLocation={false}
        toolbarEnabled={false}
      >
        <MapCircle center={approxDest} radius={450} fillColor="rgba(0,230,118,0.06)" strokeColor="rgba(0,230,118,0.35)" strokeWidth={1.5} />
        {routePts.length > 1 && (
          <Polyline coordinates={routePts} strokeWidth={3} strokeColor="#00E676" />
        )}
        {routePts.length > 1 && (
          <>
            <_RouteParticle route={routePts} delay={0}    emoji="🎸" />
            <_RouteParticle route={routePts} delay={1333} emoji="🎺" />
            <_RouteParticle route={routePts} delay={2666} emoji="🎻" />
          </>
        )}
        <Marker coordinate={approxDest} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}>
          <_DestPin />
        </Marker>
        {groupOrigin && routePts.length > 1 && (
          <Marker coordinate={groupOrigin} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}>
            <View style={qlMapSt.originDot}><View style={qlMapSt.originInner} /></View>
          </Marker>
        )}
      </MapView>
      {/* Chip de tipo — mismo lenguaje que ExpressCard */}
      <View style={qlMapSt2.typeChip} pointerEvents="none">
        <Text style={qlMapSt2.typeTx}>📅 PROGRAMADA</Text>
      </View>
      </View>
      <Text style={qlMapSt2.zone}>
        📍 {eventMunicipio}{eventEstado ? `, ${eventEstado}` : ''} — Zona aproximada
      </Text>
    </View>
  );
}
const qlMapSt2 = StyleSheet.create({
  map:         { width: '100%', height: 200 },
  typeChip: {
    position: 'absolute', top: 10, left: 10,
    flexDirection: 'row', alignItems: 'center', gap: 4,
    backgroundColor: 'rgba(0,0,0,0.72)', borderRadius: 20,
    paddingHorizontal: 8, paddingVertical: 4,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.28)',
  },
  typeTx: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: COLORS.green, letterSpacing: 0.4 },
  footer:      { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  zone:        { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, flex: 1 },
  mapsBtn:     { flexDirection: 'row', alignItems: 'center', gap: 4, paddingHorizontal: 10, paddingVertical: 6, borderRadius: RADIUS.md, backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green },
  mapsBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
});
// ─────────────────────────────────────────────────────────────────────────────

// ─── Label maps ───────────────────────────────────────────────────────────────

const EVENT_TYPE_LABELS: Record<string, string> = {
  fiesta_privada: '🎉 Fiesta privada',
  boda:           '💍 Boda',
  cumpleanos:     '🎂 Cumpleaños',
  graduacion:     '🎓 Graduación',
  empresarial:    '🏢 Empresarial',
  otro:           '🎵 Otro',
};
const COVERED_LABELS: Record<string, string> = {
  si: 'Sí, está techado', no: 'No, al aire libre', no_se: 'No sabe',
};
const VENUE_LABELS: Record<string, string> = {
  patio_pequeno:         '🏡 Patio pequeño',
  salon_mediano:         '🏛️ Salón mediano',
  jardin_grande:         '🌳 Jardín grande',
  escenario_profesional: '🎤 Escenario profesional',
};
const SOUND_LABELS: Record<string, string> = {
  // v1 (backward compat)
  si: 'Sí, necesita sonido', no: 'No necesita sonido', ya_tengo: 'Ya cuenta con sonido',
  // v2
  no_group_brings: 'No (grupo trae)',
  si_50:  'Sí, hasta 50 personas',
  si_100: 'Sí, hasta 100 personas',
  si_200: 'Sí, hasta 200 personas',
  si_300: 'Sí, 300+ personas',
};
const LIGHTING_LABELS: Record<string, string> = {
  no: 'No necesita', simple: 'Sencilla', pro: 'Profesional', premium: 'Premium',
};
const STAGE_LABELS: Record<string, string> = {
  no: 'No necesita', small: 'Chico 3×2m', medium: 'Mediano 4×3m', wedding: 'Grande boda 6×4m',
};
const LED_LABELS: Record<string, string> = {
  no: 'No necesita', medium: 'Mediana', large: 'Grande', xl: 'XL boda',
};

// ─── Types ────────────────────────────────────────────────────────────────────

export type GroupMember = {
  id: string;
  full_name: string;
  avatar_url: string | null;
  isOwner: boolean;
};

export interface QuoteFormSharedProps {
  mode: 'quote' | 'propose';

  // Financial (calculated by wrapper)
  earnings: number;
  contadoPublico: number;
  commission: number;
  commPct: string;
  ownerNet: number;

  // Quote status (mode='quote')
  isReadOnly?: boolean;
  quoteStatus?: string;
  isOwner?: boolean | null;
  ownerName?: string;

  // Event info
  eventType: string;
  eventDateStr: string;
  eventTime?: string;
  durationLabel: string;
  numPersonas?: number;
  comments?: string;

  // Location — mode='quote': map privacidad; mode='propose': zone only
  quoteId?: string;
  eventAddress?: string;
  eventLatitude?: number | null;    // pin real del cliente (quotes.latitude)
  eventLongitude?: number | null;
  eventMunicipio?: string;
  eventEstado?: string;
  onOpenMaps?: () => void;
  locationCity?: string;
  locationMunicipio?: string;
  locationEstado?: string;

  // Venue conditions
  venueCovered?: string;
  venueSize?: string;
  needsSound?: string;
  needsLighting?: string | null;
  needsStage?: string | null;
  needsLed?: string | null;

  // Client card (mode='quote')
  clientName?: string;
  clientCreatedAt?: string;
  clientAvatarUrl?: string | null;
  // Botón "Ver perfil ›" (ambos modos) — abre el perfil público del cliente
  onViewClientProfile?: () => void;

  // Form state (fully controlled)
  pricePerHour: string;
  onPriceChange: (v: string) => void;
  travelCost: string;
  onTravelChange: (v: string) => void;
  overtime1h: string;
  overtime2h: string;
  overtime3h: string;
  onOt1Change: (v: string) => void;
  onOt2Change: (v: string) => void;
  onOt3Change: (v: string) => void;
  groupNotes: string;
  onNotesChange: (v: string) => void;
  notesWarn: boolean;

  // Computed display hints
  hours: number;
  pph: number;
  base: number;
  travel: number;
  ot1Val: number;
  ot2Val: number;
  ot3Val: number;
  ot1ClientPrice: number;
  ot2ClientPrice: number;
  ot3ClientPrice: number;

  // Member distribution
  groupMembers: GroupMember[];
  memberAmounts: string[];
  onMemberAmountChange: (idx: number, val: string) => void;
  onAutoDistribute?: () => void;
  numAdditional: number;

  // Propose-only
  arrivalTime?: string;
  onArrivalTimePress?: () => void;
  startTime?: string;
  onStartTimePress?: () => void;
  hasSurge?: boolean;
  isOvertimeRequired?: boolean;
  /** El grupo tiene OTRA tocada después ese día: no se ofrecen horas extra */
  hideOvertime?: boolean;
  /** Perfil PÚBLICO del cliente (get_client_public_profile — sin teléfono/email) */
  clientProfile?: {
    full_name: string | null;
    avatar_url: string | null;
    city: string | null;
    rating: number | null;
    reviews_count: number;
    member_since: string | null;
  } | null;

  // Actions
  canSend: boolean;
  loading: boolean;
  onSend: () => void;
  onDecline?: () => void;
}

// ─── EarningsPanel (fijo fuera del scroll) ────────────────────────────────────

function EarningsPanel(p: QuoteFormSharedProps) {
  // Integrante (no dueño) — panel informativo reducido
  if (p.mode === 'quote' && p.isOwner === false) {
    return (
      <View style={ep.panel}>
        <Text style={ep.managerLabel}>Esta cotización la gestiona</Text>
        <Text style={ep.managerName}>{p.ownerName ?? 'el dueño del grupo'}</Text>
        {p.contadoPublico > 0 && (
          <Text style={ep.managerTotal}>Total acordado: ${p.contadoPublico.toLocaleString()} MXN</Text>
        )}
      </View>
    );
  }

  // Cancelada — sin monto
  if (p.quoteStatus === 'cancelled') {
    return (
      <View style={ep.panel}>
        <Text style={ep.cancelledLabel}>Cotización cancelada</Text>
      </View>
    );
  }

  // Rechazada — número en gris apagado
  if (p.quoteStatus === 'rejected') {
    return (
      <View style={ep.panel}>
        <Text style={ep.rejectedLabel}>Hubieras ganado</Text>
        {p.earnings > 0 && (
          <Text style={ep.rejectedAmount}>${p.earnings.toLocaleString()} MXN</Text>
        )}
      </View>
    );
  }

  // Sin precio aún — placeholder
  if (p.pph === 0) {
    return (
      <View style={ep.panel}>
        <Text style={ep.placeholder}>Escribe tu precio/hora para ver tu ganancia</Text>
      </View>
    );
  }

  const label = p.isReadOnly ? 'Ganarás' : 'Tu ganancia neta';

  return (
    <View style={ep.panel}>
      <Text style={ep.panelLabel}>{label}</Text>
      <Text style={ep.amount}>${p.earnings.toLocaleString()} MXN</Text>
    </View>
  );
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function DetailRow({ label, value }: { label: string; value: string }) {
  return (
    <View style={s.detailRow}>
      <Text style={s.detailLabel}>{label}</Text>
      <Text style={s.detailValue}>{value}</Text>
    </View>
  );
}

function FieldLabel({ children }: { children: string }) {
  return <Text style={s.fieldLabel}>{children}</Text>;
}

// ─── QuoteFormShared ──────────────────────────────────────────────────────────

export default function QuoteFormShared(p: QuoteFormSharedProps) {
  const isReadOnly      = p.isReadOnly ?? false;
  const overtimeReqd    = p.isOvertimeRequired ?? (p.mode === 'quote');
  const formSectionTitle = p.mode === 'quote'
    ? (isReadOnly ? 'Tu cotización enviada' : 'Tu respuesta')
    : 'Tu respuesta';

  const showMemberSection =
    p.groupMembers.length > 0 || (p.numAdditional > 0 && p.mode === 'quote');

  const otPackages = [
    { label: '+1 hora extra',  val: p.ot1Val, clientPrice: p.ot1ClientPrice, value: p.overtime1h, onChange: p.onOt1Change },
    { label: '+2 horas extra', val: p.ot2Val, clientPrice: p.ot2ClientPrice, value: p.overtime2h, onChange: p.onOt2Change },
    { label: '+3 horas extra', val: p.ot3Val, clientPrice: p.ot3ClientPrice, value: p.overtime3h, onChange: p.onOt3Change },
  ];

  return (
    <View style={s.root}>
      {/* ── Panel fijo de ganancias ───────────────────────────────────── */}
      <EarningsPanel {...p} />

      <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <ScrollView contentContainerStyle={s.scroll} showsVerticalScrollIndicator={false}>

          {/* Banner de integrante (azul, informacional) */}
          {p.mode === 'quote' && p.isOwner === false && (
            <View style={s.memberBanner}>
              <Text style={s.memberBannerText}>
                Solo el dueño del grupo puede enviar el precio al cliente. Puedes ver los detalles.
              </Text>
            </View>
          )}

          {/* Tarjeta del cliente (mode='quote') — foto + Ver perfil, como ExpressCard */}
          {p.mode === 'quote' && p.clientName && (
            <View style={s.clientCard}>
              {p.clientAvatarUrl ? (
                <Image source={{ uri: p.clientAvatarUrl }} style={s.clientAvatar} />
              ) : (
                <Text style={s.clientEmoji}>👤</Text>
              )}
              <View style={{ flex: 1 }}>
                <Text style={s.clientName}>{p.clientName}</Text>
                {p.clientCreatedAt ? <Text style={s.clientSub}>{p.clientCreatedAt}</Text> : null}
              </View>
              {p.onViewClientProfile && (
                <Pressable
                  onPress={p.onViewClientProfile}
                  hitSlop={8}
                  style={({ pressed }) => [s.viewProfileBtn, pressed && { opacity: 0.6 }]}
                >
                  <Text style={s.viewProfileTx}>Ver perfil ›</Text>
                </Pressable>
              )}
            </View>
          )}

          {/* Cliente (mode='propose') — perfil público, sin datos de contacto */}
          {p.mode === 'propose' && p.clientProfile && (
            <View style={s.clientCard}>
              {p.clientProfile.avatar_url ? (
                <Image source={{ uri: p.clientProfile.avatar_url }} style={s.clientAvatar} />
              ) : (
                <Text style={s.clientEmoji}>👤</Text>
              )}
              <View style={{ flex: 1 }}>
                <Text style={s.clientName}>{p.clientProfile.full_name ?? 'Cliente'}</Text>
                <Text style={s.clientSub}>
                  {p.clientProfile.rating != null
                    ? `⭐ ${p.clientProfile.rating} (${p.clientProfile.reviews_count} reseña${p.clientProfile.reviews_count === 1 ? '' : 's'})`
                    : 'Sin reseñas todavía'}
                  {p.clientProfile.city ? ` · ${p.clientProfile.city}` : ''}
                </Text>
                {p.clientProfile.member_since ? (
                  <Text style={s.clientSub}>
                    Miembro desde {new Date(p.clientProfile.member_since).toLocaleDateString('es-MX', { month: 'long', year: 'numeric' })}
                  </Text>
                ) : null}
              </View>
              {p.onViewClientProfile && (
                <Pressable
                  onPress={p.onViewClientProfile}
                  hitSlop={8}
                  style={({ pressed }) => [s.viewProfileBtn, pressed && { opacity: 0.6 }]}
                >
                  <Text style={s.viewProfileTx}>Ver perfil ›</Text>
                </Pressable>
              )}
            </View>
          )}

          {/* Detalles del evento */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>Detalles del evento</Text>
            <DetailRow label="Tipo"     value={EVENT_TYPE_LABELS[p.eventType] ?? p.eventType} />
            <DetailRow label="Fecha"    value={p.eventDateStr} />
            {p.eventTime ? <DetailRow label="Hora"     value={p.eventTime} />       : null}
            <DetailRow label="Duración" value={p.durationLabel} />
            {p.numPersonas != null ? <DetailRow label="Personas" value={`~${p.numPersonas}`} /> : null}
          </View>

          {/* Ubicación — mapa de privacidad para quotes, zona para propose */}
          {p.mode === 'quote' && p.quoteId && (p.eventLatitude != null || p.eventMunicipio || p.eventEstado) ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Ubicación</Text>
              <QuoteLocationMap
                quoteId={p.quoteId}
                eventLatitude={p.eventLatitude}
                eventLongitude={p.eventLongitude}
                eventMunicipio={p.eventMunicipio}
                eventEstado={p.eventEstado}
                onOpenMaps={p.onOpenMaps}
              />
            </View>
          ) : p.mode === 'propose' && p.locationEstado ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Zona del evento</Text>
              <Text style={s.locationCity}>
                📍 {p.locationCity}
                {p.locationMunicipio ? `, ${p.locationMunicipio}` : ''}, {p.locationEstado}
              </Text>
              <Text style={s.locationNote}>La dirección exacta se comparte después de confirmar el pago.</Text>
            </View>
          ) : null}

          {/* Condiciones del lugar */}
          {(p.venueCovered || p.venueSize || p.needsSound) ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Condiciones del lugar</Text>
              {p.venueCovered ? <DetailRow label="Techado"    value={COVERED_LABELS[p.venueCovered] ?? p.venueCovered} /> : null}
              {p.venueSize    ? <DetailRow label="Espacio"    value={VENUE_LABELS[p.venueSize]     ?? p.venueSize}     /> : null}
              {p.needsSound   ? <DetailRow label="🎵 Sonido" value={SOUND_LABELS[p.needsSound]   ?? p.needsSound}   /> : null}
            </View>
          ) : null}

          {/* Equipo solicitado — solo si hay al menos una categoría distinta a null/'no' */}
          {((p.needsLighting && p.needsLighting !== 'no') ||
            (p.needsStage    && p.needsStage    !== 'no') ||
            (p.needsLed      && p.needsLed      !== 'no')) ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Equipo solicitado</Text>
              {p.needsLighting && p.needsLighting !== 'no'
                ? <DetailRow label="💡 Iluminación"  value={LIGHTING_LABELS[p.needsLighting] ?? p.needsLighting} />
                : null}
              {p.needsStage && p.needsStage !== 'no'
                ? <DetailRow label="🎭 Tarima"        value={STAGE_LABELS[p.needsStage] ?? p.needsStage} />
                : null}
              {p.needsLed && p.needsLed !== 'no'
                ? <DetailRow label="📺 Pantalla LED" value={LED_LABELS[p.needsLed] ?? p.needsLed} />
                : null}
            </View>
          ) : null}

          {/* Comentarios del cliente */}
          {p.comments ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Comentarios del cliente</Text>
              <View style={s.commentBox}>
                <Text style={s.commentText}>"{p.comments}"</Text>
              </View>
            </View>
          ) : null}

          {/* ── Sección de respuesta / formulario ─────────────────────── */}
          <View style={s.section}>
            <Text style={s.sectionTitle}>{formSectionTitle}</Text>

            <FieldLabel>Tu precio neto por hora *</FieldLabel>
            <View style={s.currencyRow}>
              <DollarSign size={16} color={COLORS.muted2} />
              <TextInput
                style={s.currencyInput}
                placeholder="0"
                placeholderTextColor={COLORS.muted}
                value={p.pricePerHour}
                onChangeText={p.onPriceChange}
                keyboardType="numeric"
                editable={!isReadOnly}
              />
              <Text style={s.currencyUnit}>/hora</Text>
            </View>
            {p.pph > 0 && (
              <Text style={s.calcHint}>
                {p.hours}h × ${p.pph.toLocaleString()} = ${p.base.toLocaleString()} MXN
              </Text>
            )}

            <FieldLabel>Costo extra por traslado</FieldLabel>
            <View style={s.currencyRow}>
              <Truck size={16} color={COLORS.muted2} />
              <TextInput
                style={s.currencyInput}
                placeholder="0  (0 = sin costo)"
                placeholderTextColor={COLORS.muted}
                value={p.travelCost}
                onChangeText={p.onTravelChange}
                keyboardType="numeric"
                editable={!isReadOnly}
              />
            </View>

            {/* Distribución entre integrantes */}
            {showMemberSection && (
              <>
                <FieldLabel>Distribución de pago</FieldLabel>
                {!isReadOnly && (
                  <Text style={s.hint}>El dueño recibe el resto automáticamente.</Text>
                )}
                {!isReadOnly && p.numAdditional > 0 && p.earnings > 0 && p.onAutoDistribute && (
                  <Pressable style={s.autoSplitBtn} onPress={p.onAutoDistribute}>
                    <Scale size={15} color={COLORS.green} />
                    <Text style={s.autoSplitBtnText}>Distribuir equitativamente</Text>
                  </Pressable>
                )}
                <View style={s.membersList}>
                  {p.groupMembers.map((m) => {
                    const memberIdx = p.groupMembers.filter(x => !x.isOwner).indexOf(m);
                    return (
                      <View key={m.id} style={s.memberChip}>
                        {m.avatar_url ? (
                          <Image source={{ uri: m.avatar_url }} style={s.memberAvatar} />
                        ) : (
                          <View style={s.memberAvatarFallback}>
                            <Text style={s.memberAvatarInitial}>
                              {m.full_name?.charAt(0)?.toUpperCase() ?? '?'}
                            </Text>
                          </View>
                        )}
                        <View style={{ flex: 1 }}>
                          <Text style={s.memberChipName} numberOfLines={1}>{m.full_name}</Text>
                          {m.isOwner && <Text style={s.memberChipRole}>Dueño · resto auto</Text>}
                        </View>
                        {m.isOwner ? (
                          <View style={[s.currencyRow, s.memberAmountInput, s.memberOwnerCell]}>
                            <Text style={[s.currencyInput, { paddingVertical: 10, fontSize: 15, color: COLORS.green }]}>
                              {p.earnings > 0 ? p.ownerNet.toLocaleString() : '—'}
                            </Text>
                          </View>
                        ) : (
                          <View style={[s.currencyRow, s.memberAmountInput]}>
                            <DollarSign size={13} color={COLORS.muted2} />
                            <TextInput
                              style={[s.currencyInput, { fontSize: 15, paddingVertical: 8 }]}
                              placeholder="0"
                              placeholderTextColor={COLORS.muted}
                              value={p.memberAmounts[memberIdx] ?? ''}
                              onChangeText={v => p.onMemberAmountChange(memberIdx, v)}
                              keyboardType="numeric"
                              editable={!isReadOnly}
                            />
                          </View>
                        )}
                      </View>
                    );
                  })}
                  {/* Fallback mientras cargan los perfiles (mode='quote') */}
                  {p.groupMembers.length === 0 && p.numAdditional > 0 && (
                    Array.from({ length: p.numAdditional }).map((_, i) => (
                      <View key={i} style={s.memberChip}>
                        <View style={s.memberAvatarFallback}>
                          <Text style={s.memberAvatarInitial}>{i + 1}</Text>
                        </View>
                        <Text style={[s.memberChipName, { flex: 1 }]}>Integrante {i + 1}</Text>
                        <View style={[s.currencyRow, s.memberAmountInput]}>
                          <DollarSign size={13} color={COLORS.muted2} />
                          <TextInput
                            style={[s.currencyInput, { fontSize: 15, paddingVertical: 8 }]}
                            placeholder="0"
                            placeholderTextColor={COLORS.muted}
                            value={p.memberAmounts[i] ?? ''}
                            onChangeText={v => p.onMemberAmountChange(i, v)}
                            keyboardType="numeric"
                            editable={!isReadOnly}
                          />
                        </View>
                      </View>
                    ))
                  )}
                </View>
              </>
            )}

            {/* Hora de llegada / inicio (mode='propose') */}
            {p.mode === 'propose' && (
              <>
                <FieldLabel>Hora de llegada al evento *</FieldLabel>
                <Pressable
                  style={[s.currencyRow, p.arrivalTime ? s.timeSelected : null]}
                  onPress={p.onArrivalTimePress}
                >
                  <Clock size={16} color={p.arrivalTime ? COLORS.green : COLORS.muted2} />
                  <Text style={[s.currencyInput, {
                    paddingVertical: 14, fontSize: 16,
                    color: p.arrivalTime ? COLORS.green : COLORS.muted,
                  }]}>
                    {p.arrivalTime || 'Seleccionar hora'}
                  </Text>
                </Pressable>
                <Text style={[s.hint, { marginTop: -2, marginBottom: 14 }]}>
                  Hora en que llegará el grupo para instalarse.
                </Text>

                <FieldLabel>Hora de inicio de tocada</FieldLabel>
                <Pressable
                  style={[s.currencyRow, p.startTime ? s.timeSelected : null]}
                  onPress={p.onStartTimePress}
                >
                  <Clock size={16} color={p.startTime ? COLORS.green : COLORS.muted2} />
                  <Text style={[s.currencyInput, {
                    paddingVertical: 14, fontSize: 16,
                    color: p.startTime ? COLORS.green : COLORS.muted,
                  }]}>
                    {p.startTime || 'Seleccionar hora (opcional)'}
                  </Text>
                </Pressable>
                <Text style={[s.hint, { marginTop: -2, marginBottom: 14 }]}>
                  Hora en que comienza la música.
                </Text>
              </>
            )}

            {/* Notas para el cliente */}
            <FieldLabel>Notas para el cliente</FieldLabel>
            <TextInput
              style={s.notesInput}
              placeholder={'Ej: "Incluye sonido" · "No incluye transporte de equipo"'}
              placeholderTextColor={COLORS.muted}
              value={p.groupNotes}
              onChangeText={p.onNotesChange}
              multiline
              maxLength={300}
              editable={!isReadOnly}
              textAlignVertical="top"
            />
            {p.notesWarn && (
              <View style={s.contactWarnBox}>
                <Text style={s.contactWarnText}>⚠️ {PHONE_WARNING}</Text>
              </View>
            )}

          </View>

          {/* Respaldo garantizado (mode='propose', surge) */}
          {p.mode === 'propose' && p.hasSurge && (
            <View style={s.surgeRow}>
              <Text style={s.surgeLabel}>✨ Servicio con respaldo garantizado</Text>
            </View>
          )}

          {/* Paquetes de horas extra — ocultos si el grupo tiene otra tocada
              después ese día (el traslado de 2h es obligatorio) */}
          {p.hideOvertime ? (
            <View style={s.section}>
              <Text style={s.sectionTitle}>Paquetes de horas extra</Text>
              <Text style={s.hint}>
                🚐 Ese día tienes otra tocada después de este evento, así que no
                se ofrecerán horas extra — el tiempo de traslado es obligatorio.
              </Text>
            </View>
          ) : (
          <View style={s.section}>
            <Text style={s.sectionTitle}>
              {overtimeReqd ? 'Paquetes de horas extra *' : 'Paquetes de horas extra'}
            </Text>
            {!isReadOnly && (
              <Text style={s.hint}>
                {overtimeReqd
                  ? 'Obligatorio. El cliente podrá contratar horas extra durante el evento.'
                  : 'Opcional. El cliente podrá contratar horas extra si los llenas.'}
              </Text>
            )}
            <View style={s.overtimeGrid}>
              {otPackages.map((ot) => (
                <View key={ot.label} style={s.overtimeCard}>
                  <View style={s.overtimeHeader}>
                    <Clock size={14} color={COLORS.green} />
                    <Text style={s.overtimeLabel}>{ot.label}</Text>
                    {!isReadOnly && overtimeReqd && !ot.value && (
                      <Text style={s.reqDot}>*</Text>
                    )}
                  </View>
                  <View style={s.currencyRow}>
                    <DollarSign size={14} color={COLORS.muted2} />
                    <TextInput
                      style={[s.currencyInput, { fontSize: 16 }]}
                      placeholder="0"
                      placeholderTextColor={COLORS.muted}
                      value={ot.value}
                      onChangeText={ot.onChange}
                      keyboardType="numeric"
                      editable={!isReadOnly}
                    />
                  </View>
                  {ot.val > 0 && (
                    <Text style={s.otCommNote}>
                      Tú recibirás: ${ot.val.toLocaleString()}
                    </Text>
                  )}
                </View>
              ))}
            </View>
            {overtimeReqd && !isReadOnly && (!p.overtime1h || !p.overtime2h || !p.overtime3h) && (
              <View style={s.requiredNote}>
                <Text style={s.requiredNoteText}>
                  ⚠️ Debes llenar los 3 paquetes para enviar la cotización.
                </Text>
              </View>
            )}
          </View>
          )}

          {/* Banners de estado (mode='quote', read-only) */}
          {p.mode === 'quote' && isReadOnly && (
            <>
              {p.quoteStatus === 'quoted' && (
                <View style={s.quotedBanner}>
                  <CheckCircle size={16} color={COLORS.blue} />
                  <Text style={s.quotedBannerText}>
                    Cotización enviada — esperando respuesta del cliente
                  </Text>
                </View>
              )}
              {p.quoteStatus === 'accepted' && (
                <View style={[s.quotedBanner, { borderColor: 'rgba(0,230,118,0.4)', backgroundColor: 'rgba(0,230,118,0.08)' }]}>
                  <CheckCircle size={16} color={COLORS.green} />
                  <Text style={[s.quotedBannerText, { color: COLORS.green }]}>
                    El cliente aceptó tu cotización ✅
                  </Text>
                </View>
              )}
              {p.quoteStatus === 'rejected' && (
                <View style={[s.quotedBanner, { borderColor: 'rgba(239,83,80,0.4)', backgroundColor: 'rgba(239,83,80,0.08)' }]}>
                  <XCircle size={16} color={COLORS.red} />
                  <Text style={[s.quotedBannerText, { color: COLORS.red }]}>
                    Esta solicitud fue rechazada
                  </Text>
                </View>
              )}
            </>
          )}

          {/* Acciones */}
          {!isReadOnly && (
            <View style={p.mode === 'quote' ? s.actionsRow : undefined}>
              {p.mode === 'quote' && p.onDecline && (
                <Pressable style={s.declineBtn} onPress={p.onDecline}>
                  <XCircle size={18} color={COLORS.red} />
                  <Text style={s.declineBtnText}>Rechazar</Text>
                </Pressable>
              )}
              <Pressable
                style={[
                  s.sendBtn,
                  p.mode === 'quote' && s.sendBtnFlex,
                  (!p.canSend || p.loading) && s.sendBtnDisabled,
                ]}
                onPress={p.onSend}
                disabled={!p.canSend || p.loading}
              >
                <CheckCircle size={18} color={p.canSend ? COLORS.bg : COLORS.muted} />
                <Text style={[s.sendBtnText, !p.canSend && { color: COLORS.muted }]}>
                  {p.loading
                    ? 'Enviando...'
                    : p.mode === 'quote' ? 'Enviar cotización' : 'Enviar propuesta al cliente'}
                </Text>
              </Pressable>
            </View>
          )}

          <View style={{ height: 40 }} />
        </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

// ─── Estilos del EarningsPanel ────────────────────────────────────────────────

const ep = StyleSheet.create({
  panel: {
    backgroundColor: COLORS.card,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
    paddingHorizontal: SPACING.xl, paddingTop: 14, paddingBottom: 16,
  },
  panelLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, textTransform: 'uppercase', letterSpacing: 0.6, marginBottom: 4 },
  amount:     { fontFamily: FONTS.title, fontSize: 34, color: COLORS.green, lineHeight: 42 },

  managerLabel: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  managerName:  { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginTop: 2 },
  managerTotal: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginTop: 6 },

  rejectedLabel:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 2 },
  rejectedAmount: { fontFamily: FONTS.title, fontSize: 28, color: COLORS.muted },
  cancelledLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },
  placeholder:    { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted, textAlign: 'center', paddingVertical: 4 },
});

// ─── Estilos del scroll ───────────────────────────────────────────────────────

const s = StyleSheet.create({
  root:   { flex: 1, backgroundColor: COLORS.bg },
  scroll: { padding: SPACING.xl },

  memberBanner: {
    backgroundColor: 'rgba(66,133,244,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.3)',
    padding: 14, marginBottom: 16,
  },
  memberBannerText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.blue, flex: 1, lineHeight: 20 },

  clientCard: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 20,
  },
  clientEmoji: { fontSize: 32 },
  clientAvatar: { width: 42, height: 42, borderRadius: 21 },
  clientName:  { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text },
  clientSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  viewProfileBtn: {
    backgroundColor: 'rgba(0,230,118,0.10)', borderRadius: 20,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingHorizontal: 10, paddingVertical: 5,
  },
  viewProfileTx: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green },

  section: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 16,
  },
  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 14,
  },

  detailRow:   { flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 7, borderBottomWidth: 1, borderBottomColor: COLORS.border },
  detailLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  detailValue: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1, textAlign: 'right' },

  locationBlock: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  locationAddr:  { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  locationCity:  { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text, marginBottom: 6 },
  locationNote:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },
  mapsBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 4,
    paddingHorizontal: 10, paddingVertical: 6,
    borderRadius: RADIUS.md, backgroundColor: COLORS.greenMuted,
    borderWidth: 1, borderColor: COLORS.green,
  },
  mapsBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },

  commentBox:  {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border, padding: 12,
  },
  commentText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, lineHeight: 22, fontStyle: 'italic' },

  fieldLabel: {
    fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2,
    marginBottom: 8, marginTop: 14,
  },
  hint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18, marginBottom: 12 },

  currencyRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card2,
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, marginBottom: 4,
  },
  currencyInput: {
    flex: 1, paddingVertical: 13,
    fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.text,
  },
  currencyUnit: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  calcHint:     { fontFamily: FONTS.body, fontSize: 12, color: COLORS.green, marginBottom: 4, marginTop: 2 },

  membersList:         { gap: 8, marginBottom: 12, marginTop: 8 },
  memberChip: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 8,
  },
  memberAvatar:         { width: 36, height: 36, borderRadius: 18 },
  memberAvatarFallback: {
    width: 36, height: 36, borderRadius: 18,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  memberAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.green },
  memberChipName:      { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  memberChipRole:      { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 1 },
  memberAmountInput:   { flex: 0, width: 110, marginBottom: 0 },
  memberOwnerCell:     { borderColor: 'rgba(0,230,118,0.3)', backgroundColor: 'rgba(0,230,118,0.05)' },

  autoSplitBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.green,
    backgroundColor: 'rgba(0,230,118,0.07)',
    paddingVertical: 11, marginBottom: 12,
  },
  autoSplitBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },

  notesInput: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 13,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    minHeight: 80, marginBottom: 4,
  },

  contactWarnBox: {
    backgroundColor: 'rgba(255,179,0,0.10)', borderRadius: RADIUS.sm,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.35)',
    paddingHorizontal: 12, paddingVertical: 9, marginTop: 6,
  },
  contactWarnText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: '#FFB300', lineHeight: 17 },

  timeSelected: { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.06)' },

  surgeRow: {
    paddingVertical: 7, paddingHorizontal: 12,
    backgroundColor: 'rgba(0,230,118,0.07)',
    borderRadius: RADIUS.md, marginBottom: 6,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.20)',
  },
  surgeLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },

  overtimeGrid:   { gap: 10 },
  overtimeCard: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 12,
  },
  overtimeHeader: { flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 8 },
  overtimeLabel:  { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1 },
  reqDot:         { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.red },
  otCommNote:     { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, marginTop: 4 },
  requiredNote: {
    marginTop: 10, padding: 10, borderRadius: RADIUS.md,
    backgroundColor: 'rgba(255,152,0,0.08)', borderWidth: 1, borderColor: 'rgba(255,152,0,0.4)',
  },
  requiredNoteText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: 'rgba(255,152,0,1)' },

  quotedBanner: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    padding: 14, borderRadius: RADIUS.lg, borderWidth: 1,
    borderColor: 'rgba(66,133,244,0.4)', backgroundColor: 'rgba(66,133,244,0.08)',
    marginBottom: 12,
  },
  quotedBannerText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.blue, flex: 1 },

  actionsRow:  { flexDirection: 'row', gap: 12, marginTop: 8, marginBottom: 12 },
  declineBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    flex: 1, paddingVertical: 15, borderRadius: RADIUS.lg, borderWidth: 1,
    borderColor: 'rgba(239,83,80,0.4)', backgroundColor: 'rgba(239,83,80,0.08)',
  },
  declineBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.red },

  sendBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    paddingVertical: 15, borderRadius: RADIUS.lg, backgroundColor: COLORS.green,
    marginTop: 8, marginBottom: 12,
  },
  sendBtnFlex:     { flex: 2, marginTop: 0, marginBottom: 0 },
  sendBtnDisabled: { opacity: 0.4 },
  sendBtnText:     { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
});
