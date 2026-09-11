import { ArrowLeft, CheckCircle, Clock, Coffee, CreditCard, ExternalLink, MapPin, MessageCircle, Music2, Navigation, Play } from 'lucide-react-native';
import { CircleTimerVisual, TimerState } from '../../components/event-timer/CircleTimerVisual';
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useFocusEffect } from '@react-navigation/native';
import { useStripe } from '@stripe/stripe-react-native';
import MapView, { Circle as MapCircle, Marker, Polyline, PROVIDER_GOOGLE } from 'react-native-maps';
import Svg, { Circle, Path, Rect, Text as SvgText } from 'react-native-svg';
import {
  ActivityIndicator,
  Alert,
  Animated,
  AppState,
  Image,
  useWindowDimensions,
  Keyboard,
  Linking,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import * as Location from 'expo-location';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import { EARTH_STYLE } from '../../constants/mapStyle';
import Button from '../../components/ui/Button';
import Badge from '../../components/ui/Badge';
import RatingModal, { type RatingSubject } from '../../components/ui/RatingModal';
import { generateBreakSchedule, isPaid, parseEventDateMX } from '../../utils/calculations';
import { haversineKm, formatDist } from '../../utils/mapUtils';
import { maxExtraHoursAfter } from '../../utils/logistics';
import { ARRIVAL_RADIUS_M } from '../../utils/constants';
import { openSupport } from '../../utils/support';

const RING_R    = 145;
const RING_SW   = 14;
const RING_CIRC = 2 * Math.PI * RING_R; // ≈ 910.9

const AnimatedSvgCircle = Animated.createAnimatedComponent(Circle);

const EXTRA_MSI_OPTIONS = [1, 3, 6, 9] as const;
// ⚠️ Debe coincidir EXACTO con MSI_FEE_RATES de supabase/functions/_shared/constants.ts
// (hallazgo real 2026-09-10: aquí decía 6→8%/9→11%, el servidor cobra 6→6%/9→9% —
// el cliente veía un total distinto al que realmente se le cobraba).
const EXTRA_MSI_FEE: Record<number, number> = { 1: 0, 3: 0.05, 6: 0.06, 9: 0.09 };

// ⚠️ Debe coincidir EXACTO con la lista de complete_event (sql/639) — esta
// solo decide qué botones mostrar; la regla real vive en el servidor.
const SERVICE_DONE_CODE_GENRES = [
  'Comida', 'Fotografía', 'Renta de mesas', 'Renta de sillas',
  'Renta de brincolines', 'Inflables acuáticos',
  'Drones', 'Cabina 360', 'Cabina fotográfica',
];

const VisaLogo = () => (
  <Svg width={38} height={24} viewBox="0 0 38 24">
    <Rect width={38} height={24} rx={4} fill="#1A1F71" />
    <SvgText x="19" y="16.5" fontSize="11" fontWeight="bold" fill="white" textAnchor="middle" fontStyle="italic">VISA</SvgText>
  </Svg>
);
const McardLogo = () => (
  <Svg width={38} height={24} viewBox="0 0 38 24">
    <Rect width={38} height={24} rx={4} fill="#252525" />
    <Circle cx="15" cy="12" r="6.5" fill="#EB001B" />
    <Circle cx="23" cy="12" r="6.5" fill="#F79E1B" />
    <Path d="M19 6.8a6.5 6.5 0 0 1 0 10.4A6.5 6.5 0 0 1 19 6.8z" fill="#FF5F00" />
  </Svg>
);
const AmexLogo = () => (
  <Svg width={38} height={24} viewBox="0 0 38 24">
    <Rect width={38} height={24} rx={4} fill="#2E77BC" />
    <SvgText x="19" y="16" fontSize="9" fontWeight="bold" fill="white" textAnchor="middle" letterSpacing="1">AMEX</SvgText>
  </Svg>
);

// ── OPCIONES DE DESCANSO ──────────────────────────────────────────────
// desc es función para mostrar tiempos reales según las horas contratadas
const BREAK_OPTIONS = [
  {
    type: 'A',
    label: '15 min por hora',
    desc: (hours: number) => {
      const breakMin  = 15 * (hours - 1);
      const musicMin  = hours * 60 - breakMin;
      return `Se descansa 15 min después de cada hora, excepto la última\n${hours}h = ${formatMinutes(musicMin)} de música + ${formatMinutes(breakMin)} de descanso`;
    },
    clientVisible: true,
    breakMinutesFor: (hours: number) => 15 * (hours - 1),
    // Tiempo total en marcha = solo la música (sin contar los descansos)
    totalMinutes: (hours: number) => hours * 60 - 15 * (hours - 1),
  },
  {
    type: 'B',
    label: '15 min de descanso',
    desc: (hours: number) =>
      `Un solo descanso de 15 min a la mitad del evento\n${hours}h contratadas = ${formatMinutes(hours * 60 - 15)} de música + 15 min descanso`,
    clientVisible: true,
    breakMinutesFor: (_hours: number) => 15,
    totalMinutes: (hours: number) => hours * 60,
  },
  {
    type: 'D',
    label: 'Sin descanso',
    desc: (hours: number) =>
      `Tocan sin parar las ${hours} horas contratadas\n(Solo visible para el grupo)`,
    clientVisible: false,
    breakMinutesFor: (_hours: number) => 0,
    totalMinutes: (hours: number) => hours * 60,
  },
];

function nowMX(): Date {
  return new Date(new Date().toLocaleString('en-US', { timeZone: 'America/Mexico_City' }));
}

// Normaliza HH:MM:SS o HH:MM → HH:MM (elimina segundos si vienen de Postgres)
function normalizeHHMM(t: string | null | undefined): string {
  if (!t) return '00:00';
  return t.substring(0, 5);
}

function formatTime12h(time: string): string {
  const [hStr, mStr] = normalizeHHMM(time).split(':');
  const h = parseInt(hStr, 10);
  const ampm = h >= 12 ? 'PM' : 'AM';
  const h12 = h % 12 || 12;
  return `${h12}:${mStr} ${ampm}`;
}

function splitTime(secs: number) {
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = secs % 60;
  return { h, m, s, full: `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` };
}

function formatMinutes(mins: number) {
  if (mins === 0) return 'Sin descanso';
  if (mins < 60) return `${mins} min`;
  return `${Math.floor(mins / 60)}h ${mins % 60}min`;
}

interface TocadaTalent {
  id: string;
  status: string;
  proposed_payment_amount: number | null;
  profile: { full_name: string; avatar_url: string | null } | null;
}

interface EventPayout {
  id: string;
  user_id: string;
  role: 'owner' | 'member' | 'invited';
  amount: number;
  payout_status: 'pending' | 'paid' | 'failed';
  profile: { full_name: string } | null;
}

// ── Payment Pending overlay ───────────────────────────────────────────────────

function PaymentPendingOverlay({ reason, onClose }: { reason: string; onClose: () => void }) {
  const scaleAnim   = useRef(new Animated.Value(0.5)).current;
  const opacityAnim = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    Animated.parallel([
      Animated.spring(scaleAnim,   { toValue: 1, friction: 5, useNativeDriver: true }),
      Animated.timing(opacityAnim, { toValue: 1, duration: 350, useNativeDriver: true }),
    ]).start();
  }, []);

  return (
    <View style={pp.overlay}>
      <Animated.View style={[pp.card, { transform: [{ scale: scaleAnim }], opacity: opacityAnim }]}>
        <Text style={pp.icon}>⚠️</Text>
        <Text style={pp.title}>Esperando confirmación de pago</Text>
        <Text style={pp.body}>{reason}</Text>

        <View style={pp.infoBox}>
          <Text style={pp.infoTitle}>¿Qué pasa ahora?</Text>
          <Text style={pp.infoLine}>• El evento quedó registrado como completado</Text>
          <Text style={pp.infoLine}>• Tu pago aparece como "Pendiente de cobro" en la reserva</Text>
          <Text style={pp.infoLine}>• El cliente recibió una notificación para resolver el pago</Text>
          <Pressable onPress={() => openSupport()} hitSlop={8}>
            <Text style={[pp.infoLine, { color: COLORS.green, textDecorationLine: 'underline' }]}>
              • ¿Necesitas ayuda? Contacta a soporte
            </Text>
          </Pressable>
        </View>

        <Pressable style={pp.btn} onPress={onClose}>
          <Text style={pp.btnText}>Entendido · Ver mis reservas</Text>
        </Pressable>
      </Animated.View>
    </View>
  );
}

const pp = StyleSheet.create({
  overlay: {
    flex: 1, backgroundColor: 'rgba(4,4,4,0.92)',
    alignItems: 'center', justifyContent: 'center', padding: 28,
  },
  card: {
    width: '100%', alignItems: 'center',
    backgroundColor: COLORS.card, borderRadius: RADIUS.xl,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 28,
  },
  icon: { fontSize: 64, marginBottom: 12 },
  title: {
    fontFamily: FONTS.title, fontSize: 26, color: COLORS.text,
    textAlign: 'center', marginBottom: 10,
  },
  body: {
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 22, marginBottom: 24,
  },
  infoBox: {
    width: '100%', backgroundColor: 'rgba(255,152,0,0.08)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(255,152,0,0.3)',
    padding: 16, marginBottom: 24, gap: 6,
  },
  infoTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.orange, marginBottom: 4 },
  infoLine:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20 },
  btn: {
    width: '100%', backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 16, alignItems: 'center',
  },
  btnText: { fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.bg },
});


// ── Map helpers (espejo de IncomingExpressScreen) ─────────────────────────────
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
  'hermosillo':       { lat: 29.0729, lng: -110.9559 },
  'chihuahua':        { lat: 28.6330, lng: -106.0691 },
  'oaxaca':           { lat: 17.0732, lng: -96.7266 },
  'morelia':          { lat: 19.7060, lng: -101.1950 },
  'saltillo':         { lat: 25.4270, lng: -101.0034 },
  'durango':          { lat: 24.0277, lng: -104.6532 },
  'mazatlán':         { lat: 23.2494, lng: -106.4111 },
  'mazatlan':         { lat: 23.2494, lng: -106.4111 },
  'culiacán':         { lat: 24.8091, lng: -107.3940 },
  'culiacan':         { lat: 24.8091, lng: -107.3940 },
};
function idHash(id: string): number {
  let h = 5381;
  for (let i = 0; i < id.length; i++) h = ((h << 5) + h + id.charCodeAt(i)) | 0;
  return Math.abs(h);
}
function privacyOffset(id: string, city: string, municipio?: string | null) {
  const key = (municipio ?? city).toLowerCase().trim();
  const base =
    CITY_COORDS[key] ??
    Object.entries(CITY_COORDS).find(([k]) => key.includes(k) || k.includes(key))?.[1] ??
    { lat: 20.6597, lng: -103.3496 };
  const h = idHash(id);
  const dlat = ((h % 800) - 400) / 100_000;
  const dlng = (((h * 31) % 800) - 400) / 100_000;
  return { latitude: base.lat + dlat, longitude: base.lng + dlng };
}
function buildRoute(
  origin: { latitude: number; longitude: number },
  dest:   { latitude: number; longitude: number },
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

function RouteParticle({ route, delay, emoji = '🎵' }: { route: { latitude: number; longitude: number }[]; delay: number; emoji?: string }) {
  const [pos, setPos] = React.useState(lerpRoute(route, 0));
  const [started, setStarted] = React.useState(false);
  React.useEffect(() => {
    if (route.length < 2) return;
    let startMs: number | null = null;
    const DURATION = 4000;
    const THROTTLE = 120;
    let lastUpdate = 0;
    let frameId: number;
    const beginAt = Date.now() + delay;
    const tick = () => {
      frameId = requestAnimationFrame(tick);
      const now = Date.now();
      if (now < beginAt) return;
      if (startMs === null) { startMs = now; setStarted(true); }
      if (now - lastUpdate < THROTTLE) return;
      lastUpdate = now;
      setPos(lerpRoute(route, ((now - startMs) % DURATION) / DURATION));
    };
    frameId = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frameId);
  }, [route, delay]);
  if (!started) return null;
  return (
    <Marker coordinate={pos} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges>
      <Text style={etMapSt.noteEmoji}>{emoji}</Text>
    </Marker>
  );
}

function DestPinMarker() {
  const ring1       = React.useRef(new Animated.Value(1)).current;
  const ring2       = React.useRef(new Animated.Value(0.6)).current;
  const ring3       = React.useRef(new Animated.Value(0.3)).current;
  const glowScale   = React.useRef(new Animated.Value(1)).current;
  const glowOpacity = React.useRef(new Animated.Value(0.08)).current;
  React.useEffect(() => {
    const pulse = (val: Animated.Value, dur: number, delay: number) =>
      Animated.loop(Animated.sequence([
        Animated.delay(delay),
        Animated.timing(val, { toValue: 1.9, duration: dur, useNativeDriver: true }),
        Animated.timing(val, { toValue: 1,   duration: dur, useNativeDriver: true }),
      ]));
    pulse(ring1, 1400, 0).start();
    pulse(ring2, 1400, 350).start();
    pulse(ring3, 1400, 700).start();
    Animated.loop(Animated.sequence([
      Animated.parallel([
        Animated.timing(glowScale,   { toValue: 1.3,  duration: 2000, useNativeDriver: true }),
        Animated.timing(glowOpacity, { toValue: 0.20, duration: 2000, useNativeDriver: true }),
      ]),
      Animated.parallel([
        Animated.timing(glowScale,   { toValue: 0.85, duration: 2000, useNativeDriver: true }),
        Animated.timing(glowOpacity, { toValue: 0.05, duration: 2000, useNativeDriver: true }),
      ]),
    ])).start();
  }, []);
  return (
    <View style={etMapSt.markerWrap}>
      <Animated.View style={[etMapSt.glowBase, { opacity: glowOpacity, transform: [{ scale: glowScale }] }]} />
      <Animated.View style={[etMapSt.pulse, { width: 80, height: 80, borderRadius: 40, opacity: 0.12, transform: [{ scale: ring1 }] }]} />
      <Animated.View style={[etMapSt.pulse, { width: 52, height: 52, borderRadius: 26, opacity: 0.25, transform: [{ scale: ring2 }] }]} />
      <Animated.View style={[etMapSt.pulse, { width: 28, height: 28, borderRadius: 14, opacity: 0.45, transform: [{ scale: ring3 }] }]} />
      <View style={etMapSt.pulseCenter} />
    </View>
  );
}

const etMapSt = StyleSheet.create({
  markerWrap:  { width: 100, height: 100, alignItems: 'center', justifyContent: 'center' },
  glowBase:    { position: 'absolute', width: 120, height: 120, borderRadius: 60, backgroundColor: 'rgba(0,230,118,0.25)', borderWidth: 1.5, borderColor: 'rgba(0,230,118,0.35)' },
  pulse:       { position: 'absolute', backgroundColor: 'rgba(0,230,118,0.18)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.4)' },
  pulseCenter: { width: 12, height: 12, borderRadius: 6, backgroundColor: '#00E676', shadowColor: '#00E676', shadowOffset: { width: 0, height: 0 }, shadowOpacity: 1, shadowRadius: 10, elevation: 8 },
  noteEmoji:   { fontSize: 22, lineHeight: 26 },
  originDot:   { width: 20, height: 20, borderRadius: 10, backgroundColor: 'rgba(255,255,255,0.15)', borderWidth: 2, borderColor: '#fff', alignItems: 'center', justifyContent: 'center' },
  originInner: { width: 8, height: 8, borderRadius: 4, backgroundColor: '#fff' },
});
// ─────────────────────────────────────────────────────────────────────────────

function timeAgo(isoStr: string): string {
  const diff = new Date().getTime() - new Date(isoStr).getTime();
  const m = Math.floor(diff / 60000);
  if (m < 1) return 'ahora';
  if (m < 60) return `hace ${m} min`;
  const h = Math.floor(m / 60);
  if (h < 24) return `hace ${h}h`;
  return `hace ${Math.floor(h / 24)} días`;
}

export default function EventTimerScreen({ route, navigation }: any) {
  if (!route?.params?.reservation) {
    navigation.goBack();
    return null;
  }
  const { reservation, userRole } = route.params;
  const readOnly: boolean = route.params.readOnly ?? route.params.readonly ?? false;
  const { width: screenWidth } = useWindowDimensions();
  // Ring responsivo: máx 320px, mínimo 20px de padding lateral
  const RING_SIZE = Math.min(screenWidth * 0.80, 320);
  // client = readOnly + userRole 'client'; talent = readOnly + userRole 'talent'; group owner = !readOnly
  const canSeeDetails = !readOnly || userRole === 'talent';

  // Cotización en vivo (cuando route.params.reservation no trae quote)
  const [liveQuote, setLiveQuote] = useState<any>(reservation.quote ?? null);

  // Horas contratadas: hours_count (definitivo) → cotización → paquete → fallback 3h
  // hours_count va primero: es el valor contractual real de la reserva.
  // quote/liveQuote son solo respaldo por si la reserva no trae hours_count.
  const contractHours: number = useMemo(() =>
    (reservation.hours_count != null ? Number(reservation.hours_count) : null) ??
    reservation.quote?.duration_hours ??
    liveQuote?.duration_hours ??
    3
  , [liveQuote]);

  const clientExtraOpts = useMemo(() => {
    const q = liveQuote ?? reservation.quote;
    return [
      { hours: 1, price: (q?.overtime_1h_price ?? 0) as number },
      { hours: 2, price: (q?.overtime_2h_price ?? 0) as number },
      { hours: 3, price: (q?.overtime_3h_price ?? 0) as number },
    ].filter(o => o.price > 0);
  }, [liveQuote, reservation.quote]);

  // ⏳ Tope de horas extra: si el grupo tiene OTRA tocada después ese día,
  // no se pueden ofrecer horas extra (el traslado de 2h es obligatorio).
  const [extraHoursCap, setExtraHoursCap] = useState<number>(Infinity);
  useEffect(() => {
    maxExtraHoursAfter({
      groupId:       reservation.group_id,
      eventDate:     reservation.event_date,
      eventTime:     reservation.event_time,
      durationHours: contractHours,
    }).then(setExtraHoursCap);
  }, [contractHours]);

  const { initPaymentSheet, presentPaymentSheet } = useStripe();

  const [elapsed, setElapsed] = useState(0);
  // Inicializar isRunning sincrónico para evitar el flash gris en el primer render.
  // El useEffect posterior confirma el estado y arranca el tick.
  const [isRunning, setIsRunning] = useState(
    () => !!reservation.event_started_at &&
          reservation.status !== 'completed' &&
          !reservation.event_ended_at
  );
  const [startedAt, setStartedAt] = useState<Date | null>(null);
  const [preEventCountdown, setPreEventCountdown] = useState('');
  const [loading, setLoading] = useState(false);
  const [paymentPending, setPaymentPending] = useState(false);
  const [paymentFailReason, setPaymentFailReason] = useState('');
  const isAlreadyDone = reservation.status === 'completed' || !!reservation.event_ended_at;

  const [invitedTalents, setInvitedTalents] = useState<TocadaTalent[]>([]);
  const [payouts, setPayouts] = useState<EventPayout[]>([]);

  const [, setMemberEarning] = useState<number | null>(null);
  const [currentUserId, setCurrentUserId] = useState<string | null>(null);
  const [extraHoursAdded, setExtraHoursAdded] = useState(0);
  const [extraHoursLoaded, setExtraHoursLoaded] = useState(false);
  const [groupMemberIds, setGroupMemberIds] = useState<string[]>([]);
  const [unreadMessages, setUnreadMessages] = useState(0);
  const [showGroupConfirmModal, setShowGroupConfirmModal] = useState(false);
  const [pendingExtraRow, setPendingExtraRow] = useState<any | null>(null);
  const [showPaymentMethodModal, setShowPaymentMethodModal] = useState(false);
  const [clientPendingExtra, setClientPendingExtra] = useState<{ hours: number; price: number } | null>(null);
  const [breakType, setBreakType] = useState<string>(reservation.break_type ?? '');
  const [hasArrived, setHasArrived] = useState<boolean>(!!reservation.group_arrived_at);
  const [arrivedAt, setArrivedAt] = useState<string | null>(reservation.group_arrived_at ?? null);
  const [arriving, setArriving] = useState(false);   // verificando GPS al marcar llegada

  // 🚐 "En camino" — comparte el GPS del trayecto con el cliente (sql/473).
  // Solo mientras el timer está abierto y ANTES de marcar llegada.
  const [enRoute, setEnRoute] = useState<boolean>(!!(reservation as any).group_en_route_at);
  const transitWatchRef = useRef<Location.LocationSubscription | null>(null);

  // Solo se puede salir "en camino" el DÍA del evento, no días antes
  const isEventDay = (() => {
    const ev = reservation.event_date ? String(reservation.event_date).substring(0, 10) : null;
    if (!ev) return true;
    const n = new Date();
    const today = `${n.getFullYear()}-${String(n.getMonth() + 1).padStart(2, '0')}-${String(n.getDate()).padStart(2, '0')}`;
    return today >= ev;
  })();

  const startEnRoute = async () => {
    if (!isEventDay) {
      Alert.alert('🗓️ Aún no es el día', 'Podrás avisar que vas en camino el día del evento.');
      return;
    }
    try {
      const { status: locStatus } = await Location.requestForegroundPermissionsAsync();
      if (locStatus !== 'granted') {
        Alert.alert('📍 Activa tu ubicación', 'Necesitamos tu ubicación para que el cliente vea que vas en camino.');
        return;
      }
      const pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
      const { data: trData } = await supabase.rpc('group_update_transit', {
        p_reservation_id: reservation.id,
        p_lat: pos.coords.latitude, p_lng: pos.coords.longitude,
        p_start: true,
      });
      if ((trData as any)?.ok === false) {
        Alert.alert('No se pudo iniciar', (trData as any)?.error ?? 'Intenta de nuevo.');
        return;
      }
      setEnRoute(true);
      // Cada ~15 s o 100 m — el cliente ve la foto del grupo acercándose
      transitWatchRef.current = await Location.watchPositionAsync(
        { accuracy: Location.Accuracy.Balanced, timeInterval: 15000, distanceInterval: 100 },
        (p) => {
          void supabase.rpc('group_update_transit', {
            p_reservation_id: reservation.id,
            p_lat: p.coords.latitude, p_lng: p.coords.longitude,
            p_start: false,
          });
        },
      );
    } catch {
      Alert.alert('Error', 'No se pudo compartir tu trayecto. Intenta de nuevo.');
    }
  };

  // Al marcar llegada (o salir de la pantalla) se deja de compartir
  useEffect(() => () => { transitWatchRef.current?.remove(); }, []);
  useEffect(() => {
    if (hasArrived && transitWatchRef.current) {
      transitWatchRef.current.remove();
      transitWatchRef.current = null;
    }
  }, [hasArrived]);
  const [eventFolio, setEventFolio] = useState<string | null>((reservation as any).folio ?? null);
  const [showArrivalCodeModal, setShowArrivalCodeModal] = useState(false);
  const [arrivalCodeInput, setArrivalCodeInput] = useState(['', '', '', '']);
  const [codeLoading, setCodeLoading] = useState(false);
  const codeRef0 = useRef<any>(null);
  const codeRef1 = useRef<any>(null);
  const codeRef2 = useRef<any>(null);
  const codeRef3 = useRef<any>(null);
  // 🍽️📸🪑 Código de "servicio terminado" (sql/639, 2026-09-10) — para
  // categorías sin duración predecible (Comida, Fotografía, Renta de
  // mesas/sillas/brincolines, Inflables acuáticos, Drones, Cabina 360,
  // Cabina fotográfica). Se pide el mismo tipo de código que el de
  // llegada, pero uno NUEVO y distinto — sin límite de tiempo.
  const [needsServiceCode, setNeedsServiceCode] = useState(false);
  const [showServiceCodeModal, setShowServiceCodeModal] = useState(false);
  const [serviceCodeInput, setServiceCodeInput] = useState(['', '', '', '']);
  const [serviceCodeLoading, setServiceCodeLoading] = useState(false);
  const svcCodeRef0 = useRef<any>(null);
  const svcCodeRef1 = useRef<any>(null);
  const svcCodeRef2 = useRef<any>(null);
  const svcCodeRef3 = useRef<any>(null);
  const [eventLatLng, setEventLatLng] = useState<{ lat: number; lng: number } | null>(null);
  const [approxDest,  setApproxDest]  = useState<{ latitude: number; longitude: number } | null>(null);
  const [groupOrigin, setGroupOrigin] = useState<{ latitude: number; longitude: number } | null>(null);
  const [routePts,    setRoutePts]    = useState<{ latitude: number; longitude: number }[]>([]);
  const mapRef = useRef<MapView>(null);
  const [showBreakModal, setShowBreakModal] = useState(false);
  const [pendingStartAfterBreak, setPendingStartAfterBreak] = useState(false);
  const [showClientNearEndModal, setShowClientNearEndModal] = useState(false);
  const clientNearEndShownRef = useRef(false);
  const partialExtraReleasedRef = useRef(false);
  const [showMsiModal, setShowMsiModal] = useState(false);
  const [msiPendingChoice, setMsiPendingChoice] = useState<{ hours: number; price: number } | null>(null);
  const [msiSelectedMonths, setMsiSelectedMonths] = useState<number>(1);
  // Moneda real de la reserva — SIN fallback silencioso a MXN. Varios
  // caminos de navegación hacia esta pantalla no incluyen currency_code en
  // su select (ver auditoría), así que se reconfirma aquí con un refetch
  // aislado. Mientras sea null (fetch en curso o falló), los montos que
  // dependen de esto se muestran SIN sufijo de moneda — nunca se asume MXN.
  const [resCurrency, setResCurrency] = useState<'MXN' | 'USD' | null>(null);
  const [pendingPaymentExtra, setPendingPaymentExtra] = useState<{
    id: string; hours: number; price: number; msiMonths: number;
  } | null>(null);
  const [stripeLoading, setStripeLoading] = useState(false);
  const [ratingQueue, setRatingQueue]       = useState<RatingSubject[]>([]);
  const [currentRating, setCurrentRating]   = useState<RatingSubject | null>(null);
  const [hasAlreadyRated, setHasAlreadyRated] = useState(false);
  const [reviewReceived, setReviewReceived] = useState<{ rating: number; comment?: string; createdAt?: string } | null>(null);
  const [payoutInfo, setPayoutInfo] = useState<{
    payout_status:  'held' | 'released' | 'blocked' | 'refunded' | null;
    payment_status: string | null;
    payout_completed: boolean;
  }>({ payout_status: null, payment_status: null, payout_completed: false });
  const [now, setNow] = useState(() => nowMX());

  // Cargar cotización desde DB cuando no viene en route.params
  useEffect(() => {
    if (liveQuote || !reservation.quote_id) return;
    supabase
      .from('quotes')
      .select('id, overtime_1h_price, overtime_2h_price, overtime_3h_price, duration_hours, event_type, notes')
      .eq('id', reservation.quote_id)
      .maybeSingle()
      .then(({ data }) => { if (data) setLiveQuote(data); });
  }, []);

  // Pre-check: two separate queries.
  // 1. gaveQuery  — ¿ya califiqué al otro? → hasAlreadyRated (controla modal)
  // 2. receivedQuery — ¿qué me dieron? → reviewReceived (muestra tarjeta verde)
  useEffect(() => {
    if (!reservation?.id) return;
    (async () => {
      const { data: sessionData } = await supabase.auth.getSession();
      const myUserId = sessionData?.session?.user.id ?? '';

      // ── Query 1: ¿Ya di yo una calificación? ─────────────────────────
      let alreadyRated = false;
      if (userRole === 'client') {
        const { data } = await supabase.from('reviews')
          .select('id').eq('reservation_id', reservation.id).limit(1);
        alreadyRated = !!data?.length;
      } else if (userRole !== 'talent') {
        const { data } = await supabase.from('client_reviews')
          .select('id').eq('reservation_id', reservation.id)
          .eq('group_id', reservation.group_id ?? '').limit(1);
        alreadyRated = !!data?.length;
      }
      if (alreadyRated) setHasAlreadyRated(true);

      // ── Query 2: ¿Me dieron una calificación a mí? ───────────────────
      let receivedData: { rating: number; comment: string | null; created_at: string } | null = null;
      if (userRole === 'client') {
        const { data } = await supabase.from('client_reviews')
          .select('rating, comment, created_at')
          .eq('reservation_id', reservation.id).limit(1);
        receivedData = data?.[0] ?? null;
      } else if (userRole === 'talent') {
        const { data } = await supabase.from('talent_reviews')
          .select('rating, comment, created_at')
          .eq('reservation_id', reservation.id)
          .eq('talent_id', myUserId).limit(1);
        receivedData = data?.[0] ?? null;
      } else {
        const { data } = await supabase.from('reviews')
          .select('rating, comment, created_at')
          .eq('reservation_id', reservation.id).limit(1);
        receivedData = data?.[0] ?? null;
      }
      if (receivedData) {
        setReviewReceived({
          rating: receivedData.rating,
          comment: receivedData.comment ?? undefined,
          createdAt: receivedData.created_at ?? undefined,
        });
      }

      if (isAlreadyDone && !alreadyRated && userRole !== 'talent') {
        startRatingFlow();
      }
    })();
  }, [reservation?.id]);

  // Cargar estado fresco desde DB al montar (resuelve re-navegación)
  useEffect(() => {
    supabase
      .from('reservations')
      .select('status, event_ended_at, event_started_at, group_arrived_at, break_type, folio')
      .eq('id', reservation.id)
      .single()
      .then(({ data }) => {
        if (!data) return;
        // Restaurar tipo de descanso (BUG 3 fix: el nav param puede traerlo vacío)
        if (data.break_type) setBreakType(data.break_type);
        // Folio: el nav param a veces no lo trae → mostrarlo siempre en el timer
        if (data.folio) setEventFolio(data.folio);
        // Restaurar llegada
        if (data.group_arrived_at) {
          setHasArrived(true);
          setArrivedAt(data.group_arrived_at);
        }
        if (data.status === 'completed' || data.event_ended_at) {
          autoFinishedRef.current = true;
          if (intervalRef.current) clearInterval(intervalRef.current);
          setIsRunning(false);
          // BUG E: cuando el grupo re-abre un evento completado, elapsed=0 (no hay tick).
          // Seteamos elapsed con la duración real para que finalElapsedSeconds muestre
          // el total correcto (ej. 5:00:00 con 1h extra) en vez del fallback totalMusicSecs.
          if (data.event_ended_at && data.event_started_at) {
            setElapsed(Math.max(0, Math.floor(
              (new Date(data.event_ended_at).getTime() - new Date(data.event_started_at).getTime()) / 1000
            )));
          }
        } else if (data.event_started_at) {
          // Reanudar timer si el evento sigue in_progress en DB.
          // No se limita por contractHours: extra hours pueden extender el evento.
          // El auto-stop real lo maneja L1312 con totalMusicSecs (incluye extras).
          const elapsedSecs = Math.floor((Date.now() - new Date(data.event_started_at).getTime()) / 1000);
          if (elapsedSecs >= 0) {
            const start = new Date(data.event_started_at);
            setStartedAt(start);
            setElapsed(elapsedSecs);
            setIsRunning(true);
            // [Fix 2026-09-09] Faltaba arrancar el conteo aquí — este branch
            // solo corre cuando el prop `reservation` (nav params) NO traía
            // event_started_at (p.ej. se llegó por una ruta con datos
            // incompletos) y hubo que confirmarlo con un refetch directo a
            // la BD. Sin este startTick(), isRunning quedaba en true pero
            // el número del cronómetro se congelaba en el valor calculado
            // una sola vez — nunca volvía a avanzar. startTick() ya limpia
            // cualquier intervalo previo, así que llamarlo aquí es seguro
            // incluso si el otro efecto de inicialización ya lo arrancó.
            startTick(start);
          }
        } else if (
          !readOnly &&
          !autoStartedRef.current &&
          eventTargetMs != null &&
          data.status === 'confirmed' &&
          data.group_arrived_at &&
          Date.now() >= eventTargetMs + 10 * 60 * 1000 &&
          Date.now() <= eventTargetMs + 6 * 3600 * 1000
        ) {
          // Recovery: ventana de auto-inicio pasó mientras la app estuvo cerrada
          autoStartedRef.current = true;
          confirmStart(breakType || 'B');
        }
      });
  }, []);

  // ── Moneda real de la reserva (aislado — no toca el efecto de arriba) ────
  // Varios puntos de navegación hacia esta pantalla no traen currency_code
  // en su select. Este refetch mínimo lo confirma directo desde la BD, sin
  // asumir nada. Si falla, se loguea y resCurrency se queda en null — los
  // montos que lo usan se muestran sin sufijo de moneda, nunca "MXN" por
  // default.
  useEffect(() => {
    supabase
      .from('reservations')
      .select('currency_code')
      .eq('id', reservation.id)
      .single()
      .then(({ data, error }) => {
        if (error || !data?.currency_code) {
          console.warn('[EventTimer] No se pudo confirmar currency_code:', error?.message ?? 'sin dato');
          return;
        }
        setResCurrency(data.currency_code === 'USD' ? 'USD' : 'MXN');
      });
  }, [reservation.id]);

  // ── Categoría del proveedor (aislado, mismo criterio que arriba) ─────────
  // Determina si esta reserva cierra por código de "servicio terminado"
  // (sql/639) en vez de por duración — mismo listado de géneros que usa
  // complete_event en el servidor, la fuente de verdad real es esa; esto
  // solo decide qué botones mostrar.
  useEffect(() => {
    supabase
      .from('reservations')
      .select('group:groups(genre)')
      .eq('id', reservation.id)
      .single()
      .then(({ data, error }) => {
        const genre = (data as any)?.group?.genre;
        if (error || !genre) return;
        setNeedsServiceCode(SERVICE_DONE_CODE_GENRES.includes(genre));
      });
  }, [reservation.id]);

  // Restaurar estado de llegada y descanso al volver a la pantalla
  // (native-stack mantiene el componente montado: useFocusEffect re-corre en cada focus)
  useFocusEffect(
    useCallback(() => {
      supabase
        .from('reservations')
        .select('group_arrived_at, break_type')
        .eq('id', reservation.id)
        .single()
        .then(({ data }) => {
          if (!data) return;
          if (data.break_type) setBreakType(data.break_type);
          if (data.group_arrived_at) {
            setHasArrived(true);
            setArrivedAt(data.group_arrived_at);
          }
        });
    }, [reservation.id])
  );

  // Ticker para mantener `now` actualizado (para canStartNow y auto-start)
  useEffect(() => {
    const id = setInterval(() => setNow(nowMX()), 30_000);
    return () => clearInterval(id);
  }, []);

  // Activar auto-start solo después de 2 s (evita disparar en primer render)
  useEffect(() => {
    const id = setTimeout(() => { autoStartReadyRef.current = true; }, 2000);
    return () => clearTimeout(id);
  }, []);

  // Auto-inicio: solo si el grupo ya llegó, pasó la hora + 10 min, evento es de hoy y no está terminado
  useEffect(() => {
    if (!autoStartReadyRef.current) return;
    if (readOnly || startedAt || eventTargetMs == null || autoStartedRef.current || !hasArrived) return;
    if (isAlreadyDone || reservation.status === 'completed') return;
    const graceMs  = 10 * 60 * 1000;   // 10 min de gracia
    const windowMs = 6 * 3600 * 1000;  // solo eventos de las últimas 6 h
    const now_ms   = Date.now();
    const eventMs  = eventTargetMs;
    if (now_ms < eventMs + graceMs) return;   // todavía dentro de la gracia
    if (now_ms > eventMs + windowMs) return;  // evento viejo, no auto-iniciar
    autoStartedRef.current = true;
    confirmStart(breakType || 'B');
  }, [now, hasArrived]);


  const progressAnim      = useRef(new Animated.Value(0)).current;
  const pulseAnim         = useRef(new Animated.Value(1)).current;
  const ringColorAnim     = useRef(new Animated.Value(0)).current;
  const ringColorPhaseRef = useRef(0);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const sentMilestones = useRef<Set<string>>(new Set());
  const warned15MinRef  = useRef(false);
  const warned2hRef     = useRef(false);
  const autoStartedRef  = useRef(false);
  const autoStartReadyRef = useRef(false);
  const warned30MinRef = useRef(false);
  const autoFinishedRef = useRef(false);
  const ownerIdRef = useRef<string | null>(null);
  // Trackea qué IDs de extra_hours ya sumamos a extraHoursAdded (evita doble conteo
  // cuando el mismo row recibe múltiples UPDATEs mientras status='accepted').
  const countedExtraIds = useRef<Set<string>>(new Set());

  const selectedBreak = BREAK_OPTIONS.find(o => o.type === breakType);
  const breakMins = selectedBreak ? selectedBreak.breakMinutesFor(contractHours) : 0;

  // Tiempo total del evento en segundos (base + horas extra con su descanso de 15 min c/u)
  const totalSecs = selectedBreak
    ? selectedBreak.totalMinutes(contractHours) * 60 + extraHoursAdded * 75 * 60
    : contractHours * 3600 + extraHoursAdded * 75 * 60;

  // Hora del evento resuelta y normalizada: la reserva o su cotización
  // (las reservas por cotización a veces dejan reservation.event_time null y
  //  la hora vive en la quote). "8:00" → "08:00" para que parseEventDateMX no falle.
  const rawEventTime: string | null =
    reservation.event_time ?? (reservation as any).quote?.event_time ?? null;
  const normEventTime: string | null = rawEventTime
    ? (() => {
        const [h, m] = rawEventTime.split(':');
        return `${(h ?? '0').padStart(2, '0')}:${(m ?? '00').substring(0, 2).padStart(2, '0')}`;
      })()
    : null;

  // Fecha del evento limpia a YYYY-MM-DD (si viene "2026-07-05T00:00:00" el
  // regex de parseEventDateMX fallaba → null). Se usa para construir eventTargetMs.
  const eventDateOnly = reservation.event_date ? String(reservation.event_date).substring(0, 10) : null;

  // Instante del evento en UTC directo (México = UTC-6 fijo, sin horario de
  // verano desde 2022). No depende del regex de parseEventDateMX ni del
  // timezone del dispositivo → cuenta bien en cualquier build/emulador.
  const eventTargetMs = (eventDateOnly && normEventTime)
    ? (() => {
        const t = Date.parse(`${eventDateOnly}T${normEventTime}:00-06:00`);
        return isNaN(t) ? null : t;
      })()
    : null;

  // [Opción A] Ventana de inicio manual: desde 30 min ANTES hasta 6 h DESPUÉS
  // de la hora del evento. Antes se bloqueaba pasada la hora exacta → un grupo
  // que abría la app tarde no podía iniciar y el evento quedaba atorado.
  // El candado GPS del 50% NO cambia: iniciar tarde igual exige marcar llegada
  // (release_half_on_arrival) para liberar el pago — solo se amplía el tiempo.
  const canStartNow = !startedAt && eventTargetMs != null
    ? (() => {
        const diffMs = eventTargetMs - Date.now();
        return diffMs <= 30 * 60 * 1000 && diffMs >= -6 * 60 * 60 * 1000;
      })()
    : false;

  // Schedule & current segment
  const schedule = useMemo(() => {
    const effectiveStart =
      startedAt ?? parseEventDateMX(reservation.event_date, reservation.event_time);
    if (!effectiveStart || !breakType) return [];
    return generateBreakSchedule(effectiveStart, contractHours, breakType, extraHoursAdded);
  }, [startedAt, breakType, contractHours, extraHoursAdded, reservation.event_date, reservation.event_time]);

  const currentSegment = useMemo(() => {
    const elapsedMin = elapsed / 60;
    return schedule.find(seg => elapsedMin >= seg.fromMin && elapsedMin < seg.toMin) ?? null;
  }, [elapsed, schedule]);

  // Tiempo SOLO de música en segundos (excluye descansos)
  const totalMusicSecs = useMemo(() => {
    if (!schedule.length) return contractHours * 3600;
    return schedule
      .filter(s => s.type === 'music')
      .reduce((sum, s) => sum + (s.toMin - s.fromMin) * 60, 0);
  }, [schedule, contractHours]);

  // Tiempo transcurrido SOLO en segmentos de música (el timer se "pausa" durante descansos)
  const musicElapsed = useMemo(() => {
    if (!schedule.length) return elapsed;
    let music = 0;
    for (const seg of schedule) {
      if (seg.type !== 'music') continue;
      const segStart = seg.fromMin * 60;
      const segEnd   = seg.toMin   * 60;
      if (elapsed <= segStart) break;
      music += Math.min(elapsed, segEnd) - segStart;
    }
    return music;
  }, [elapsed, schedule]);

  // ── Derived timing state (needed before useEffects) ─────────────────────
  const remaining  = Math.max(0, totalMusicSecs - musicElapsed);
  const nearEnd    = remaining <= 900 && remaining > 0;

  useEffect(() => {
    if (reservation.event_started_at) {
      const start    = new Date(reservation.event_started_at);
      const nowSecs  = Math.floor((Date.now() - start.getTime()) / 1000);
      // isAlreadyOver: confiar solo en status/event_ended_at de DB
      // (extra hours pueden extender el evento más allá de contractHours)
      const isAlreadyOver  = reservation.status === 'completed'
        || !!reservation.event_ended_at;

      setStartedAt(start);
      autoFinishedRef.current = isAlreadyOver;

      if (!isAlreadyOver) {
        // Evento en curso: reanudar timer
        setIsRunning(true);
        setElapsed(nowSecs);
        startTick(start);
      }
    }
    return () => { if (intervalRef.current) clearInterval(intervalRef.current); };
  }, []);

  // Realtime: when the group starts the event, client and group owner see the timer update
  useEffect(() => {
    const channel = supabase
      .channel(`res-live-${reservation.id}`)
      .on('postgres_changes', {
        event: 'UPDATE',
        schema: 'public',
        table: 'reservations',
        filter: `id=eq.${reservation.id}`,
      }, (payload: any) => {
        const upd = payload.new;
        if (upd.break_type) setBreakType(upd.break_type);
        if (upd.group_arrived_at) {
          setHasArrived(true);
          setArrivedAt(upd.group_arrived_at);
        }
        if (upd.event_started_at) {
          const start = new Date(upd.event_started_at);
          setStartedAt(start);
          setIsRunning(true);
          startTick(start);
        }
        // Bug 5: cliente ve "en curso" aunque el grupo ya finalizó
        if (upd.status === 'completed' || upd.event_ended_at) {
          setIsRunning(false);
          if (intervalRef.current) clearInterval(intervalRef.current);
          startRatingFlow();
        }
      })
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, []);

  // Contador regresivo hasta que inicie el evento (usa eventTargetMs de arriba)
  useEffect(() => {
    if (startedAt || eventTargetMs == null) { setPreEventCountdown(''); return; }
    const tick = () => {
      const diff = eventTargetMs - Date.now();
      if (diff <= 0) { setPreEventCountdown(''); return; }
      const d = Math.floor(diff / 86_400_000);
      const h = Math.floor((diff % 86_400_000) / 3_600_000);
      const m = Math.floor((diff % 3_600_000) / 60_000);
      const s = Math.floor((diff % 60_000) / 1_000);
      if (d > 0) setPreEventCountdown(`${d}d ${h}h ${String(m).padStart(2,'0')}m ${String(s).padStart(2,'0')}s`);
      else setPreEventCountdown(`${h}h ${String(m).padStart(2,'0')}m ${String(s).padStart(2,'0')}s`);
    };
    tick();
    const id = setInterval(tick, 1_000);
    return () => clearInterval(id);
  }, [startedAt, eventTargetMs]);

  useEffect(() => {
    if (!reservation.event_id && !reservation.event_request_id) return;
    const q = supabase
      .from('job_invitations')
      .select('id, invited_user_id, status, proposed_payment_amount, profile:invited_user_id(full_name, avatar_url)')
      .eq('invitation_type', 'event')
      .in('status', ['accepted']);
    if (reservation.event_id) q.eq('event_id', reservation.event_id);
    else if (reservation.event_request_id) q.eq('event_request_id', reservation.event_request_id);
    q.then(({ data }) => { if (data) setInvitedTalents(data as any); });
  }, []);

  useEffect(() => {
    supabase
      .from('event_payouts')
      .select('id, user_id, role, amount, payout_status, profile:user_id(full_name)')
      .eq('reservation_id', reservation.id)
      .then(({ data }) => { if (data) setPayouts(data as any); });
  }, []);

  // Ganancia del integrante según package_member_distribution
  useEffect(() => {
    if (!readOnly || !reservation.package_id) return;
    supabase.auth.getSession().then(({ data }) => {
      if (!data.session) return;
      supabase
        .from('package_member_distribution')
        .select('amount')
        .eq('package_id', reservation.package_id)
        .eq('user_id', data.session.user.id)
        .maybeSingle()
        .then(({ data: dist }) => { if (dist) setMemberEarning(dist.amount); });
    });
  }, []);

  useEffect(() => {
    const progress = Math.min(elapsed / totalSecs, 1);
    Animated.timing(progressAnim, {
      toValue: progress, duration: 500, useNativeDriver: false,
    }).start();
  }, [elapsed, totalSecs]);

  // ── Cargar horas extra aceptadas al montar + realtime ────────────────────
  useEffect(() => {
    // Carga inicial — incluir 'paid' además de 'accepted' para Stripe flow.
    // Registramos los IDs cargados en countedExtraIds para evitar doble conteo
    // si el realtime UPDATE dispara después por el mismo row.
    supabase
      .from('extra_hours')
      .select('id, hours_added')
      .eq('reservation_id', reservation.id)
      .in('status', ['accepted', 'paid'])
      .then(({ data }) => {
        if (data && data.length > 0) {
          const total = data.reduce((s: number, r: any) => s + (r.hours_added ?? 0), 0);
          data.forEach((r: any) => { if (r.id) countedExtraIds.current.add(r.id); });
          setExtraHoursAdded(total);
        }
        setExtraHoursLoaded(true);
      });

    // Restaurar estado si el cliente reabre la pantalla
    if (readOnly) {
      supabase
        .from('extra_hours')
        .select('id, hours_added, total_extra_cost, status, msi_months')
        .eq('reservation_id', reservation.id)
        .in('status', ['awaiting_group_confirmation', 'pending_payment'])
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle()
        .then(({ data: pending }) => {
          if (!pending) return;
          if (pending.status === 'pending_payment') {
            setPendingPaymentExtra({
              id: pending.id,
              hours: pending.hours_added,
              price: pending.total_extra_cost,
              msiMonths: pending.msi_months ?? 1,
            });
          } else {
            setClientPendingExtra({ hours: pending.hours_added, price: pending.total_extra_cost });
          }
        });
    } else {
      // Grupo: mostrar modal si llegó desde notificación y el INSERT de Realtime ya fue perdido
      supabase
        .from('extra_hours')
        .select('*')
        .eq('reservation_id', reservation.id)
        .eq('status', 'awaiting_group_confirmation')
        .maybeSingle()
        .then(({ data: pendingRow }) => {
          if (pendingRow) {
            setPendingExtraRow(pendingRow);
            setShowGroupConfirmModal(true);
          }
        });
    }

    // Realtime: nuevo registro de horas extra (cliente solicitó)
    const ch = supabase
      .channel(`extra-hours-${reservation.id}`)
      .on('postgres_changes', {
        event: 'INSERT', schema: 'public', table: 'extra_hours',
        filter: `reservation_id=eq.${reservation.id}`,
      }, (payload: any) => {
        const row = payload.new;
        if (row.status === 'accepted') {
          // Path A (grupo oferta directa ya aceptada por cliente)
          if (row.id && !countedExtraIds.current.has(row.id)) {
            countedExtraIds.current.add(row.id);
            setExtraHoursAdded(prev => prev + (row.hours_added ?? 0));
          }
        } else if (row.status === 'awaiting_group_confirmation') {
          if (!readOnly) {
            // Grupo ve el modal de confirmación con desglose de comisión
            setPendingExtraRow(row);
            setShowGroupConfirmModal(true);
          }
          // Cliente ya sabe que está pendiente (setClientPendingExtra fue llamado localmente)
        }
      })
      .on('postgres_changes', {
        event: 'UPDATE', schema: 'public', table: 'extra_hours',
        filter: `reservation_id=eq.${reservation.id}`,
      }, (payload: any) => {
        const row = payload.new;
        if (row.status === 'accepted') {
          // Grupo aceptó (balance flow): actualizar anillo para cliente + músicos vía Realtime
          if (row.id && !countedExtraIds.current.has(row.id)) {
            countedExtraIds.current.add(row.id);
            setExtraHoursAdded(prev => prev + (row.hours_added ?? 0));
          }
          setClientPendingExtra(null);
        } else if (row.status === 'pending_payment') {
          // Grupo aceptó (stripe flow): mostrar banner "Paga ahora" al cliente
          if (readOnly) {
            setPendingPaymentExtra({
              id: row.id,
              hours: row.hours_added ?? 0,
              price: row.total_extra_cost ?? 0,
              msiMonths: row.msi_months ?? 1,
            });
            setClientPendingExtra(null);
          }
        } else if (row.status === 'paid') {
          // Pago Stripe confirmado por webhook: actualizar anillo automáticamente
          if (row.id && !countedExtraIds.current.has(row.id)) {
            countedExtraIds.current.add(row.id);
            setExtraHoursAdded(prev => prev + (row.hours_added ?? 0));
          }
          setClientPendingExtra(null);
          setPendingPaymentExtra(null);
        } else if (row.status === 'rejected' && readOnly) {
          // Grupo rechazó: limpiar estado de espera del cliente
          setClientPendingExtra(null);
          setPendingPaymentExtra(null);
        }
      })
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, []);

  // ── Mensajes no leídos en el chat ─────────────────────────────────────────
  useEffect(() => {
    const chatCh = supabase
      .channel(`chat-badge-${reservation.id}`)
      .on('postgres_changes', {
        event: 'INSERT', schema: 'public',
        table: 'reservation_messages',
        filter: `reservation_id=eq.${reservation.id}`,
      }, (payload: any) => {
        // Solo contar mensajes del otro lado
        if (payload.new.sender_id !== currentUserId) {
          setUnreadMessages(prev => prev + 1);
        }
      })
      .subscribe();
    return () => { supabase.removeChannel(chatCh); };
  }, [currentUserId]);

  // ── Cargar IDs de miembros del grupo para notificaciones ──────────────────
  useEffect(() => {
    if (!reservation.group_id) return;
    supabase
      .from('groups').select('owner_id').eq('id', reservation.group_id).single()
      .then(async ({ data: grp }) => {
        const ids: string[] = grp?.owner_id ? [grp.owner_id] : [];
        const { data: invs } = await supabase
          .from('job_invitations')
          .select('invited_user_id')
          .eq('group_id', reservation.group_id)
          .eq('status', 'accepted')
          .is('event_id', null);
        (invs ?? []).forEach((i: any) => { if (!ids.includes(i.invited_user_id)) ids.push(i.invited_user_id); });
        // Talentos invitados y aceptados a ESTE evento (misma regla que sql/421/422)
        if (reservation.event_id || reservation.event_request_id) {
          const evQ = supabase
            .from('job_invitations')
            .select('invited_user_id')
            .eq('invitation_type', 'event')
            .eq('status', 'accepted');
          if (reservation.event_id) evQ.eq('event_id', reservation.event_id);
          else evQ.eq('event_request_id', reservation.event_request_id);
          const { data: evInvs } = await evQ;
          (evInvs ?? []).forEach((i: any) => { if (!ids.includes(i.invited_user_id)) ids.push(i.invited_user_id); });
        }
        setGroupMemberIds(ids);
        ownerIdRef.current = ids[0] ?? null;
      });
  }, []);

  // ── Aviso 15 min antes del fin → notificar al cliente ────────────────────
  useEffect(() => {
    if (readOnly || !isRunning || sentMilestones.current.has('15min')) return;
    const remaining = Math.max(0, totalSecs - elapsed);
    if (remaining <= 900 && remaining > 0) {
      sentMilestones.current.add('15min');
      warned15MinRef.current = true;
      if (reservation.client_id) {
        // [Fix 2026-09-09] sentMilestones es solo memoria del componente —
        // se reinicia si la pantalla se vuelve a montar (p.ej. el SO mató
        // la app a mitad del evento). Verificar contra la BD antes de
        // insertar evita mandar este aviso dos veces en ese caso.
        supabase
          .from('notifications')
          .select('id')
          .eq('type', 'reservation')
          .contains('data', { reservation_id: reservation.id, milestone: '15min' })
          .limit(1)
          .then(({ data: existing }) => {
            if (existing && existing.length > 0) return;
            supabase.from('notifications').insert([{
              user_id: reservation.client_id,
              type: 'reservation',
              title: '⏰ Quedan 15 minutos',
              body: '¿Quieres más tiempo? Puedes agregar horas extra desde el temporizador.',
              data: { reservation_id: reservation.id, milestone: '15min' },
            }]);
          });
      }
    }
  }, [elapsed, isRunning]);

  // ── Modal horas extra cliente — aparece una sola vez al llegar a nearEnd ────
  useEffect(() => {
    if (!isRunning || !nearEnd || userRole !== 'client') return;
    if (!extraHoursLoaded) return;
    if (clientNearEndShownRef.current || clientExtraOpts.length === 0) return;
    if (extraHoursAdded > 0) return;
    if (pendingPaymentExtra) return;
    clientNearEndShownRef.current = true;
    setShowClientNearEndModal(true);
  }, [nearEnd, isRunning, extraHoursAdded, extraHoursLoaded]);

  // ── Liberar 50% extras al cruzar el tiempo contractual (grupo owner) ────────
  useEffect(() => {
    if (!isRunning || readOnly) return;
    if (partialExtraReleasedRef.current) return;
    if (elapsed < contractHours * 3600) return;
    if (extraHoursAdded === 0) return;
    partialExtraReleasedRef.current = true;
    supabase.rpc('release_extra_hours_partial', { p_reservation_id: reservation.id })
      .then(({ error }) => {
        if (error) console.warn('[ExtraPartial] Error:', error.message);
      });
  }, [elapsed, isRunning, extraHoursAdded]);

  // ── Aviso a las 2 horas → oferta de horas extra al cliente ───────────────
  useEffect(() => {
    if (!isRunning || sentMilestones.current.has('2h') || readOnly) return;
    if (elapsed >= 7200 && contractHours > 2) {
      sentMilestones.current.add('2h');
      warned2hRef.current = true;
      if (reservation.client_id) {
        const pricePerHour = Math.round((reservation.total_price ?? 0) / contractHours);
        // [Fix 2026-09-09] mismo caso que el aviso de 15 min: verificar
        // contra la BD antes de insertar evita duplicados si la pantalla
        // se remonta dentro de esta misma ventana de tiempo.
        supabase
          .from('notifications')
          .select('id')
          .eq('type', 'extra_hours_offer')
          .contains('data', { reservation_id: reservation.id, milestone: '2h' })
          .limit(1)
          .then(({ data: existing }) => {
            if (existing && existing.length > 0) return;
            supabase.from('notifications').insert([{
              user_id: reservation.client_id,
              type: 'extra_hours_offer',
              title: '🎵 ¡Ya llevan 2 horas de música!',
              body: `¿Quieres que continúen? Puedes contratar horas extra desde $${pricePerHour.toLocaleString()}/hr.`,
              data: { reservation_id: reservation.id, price_per_hour: pricePerHour, milestone: '2h' },
            }]);
          });
      }
    }
  }, [elapsed, isRunning]);

  // ── Aviso 30 min antes del fin ────────────────────────────────────────────
  useEffect(() => {
    if (!isRunning || sentMilestones.current.has('30min') || readOnly) return;
    const remaining = Math.max(0, totalSecs - elapsed);
    if (remaining <= 1800 && remaining > 0) {
      sentMilestones.current.add('30min');
      warned30MinRef.current = true;
      if (reservation.client_id) {
        const pricePerHour = Math.round((reservation.total_price ?? 0) / contractHours);
        // [Fix 2026-09-09] mismo caso que los avisos de 15 min / 2h.
        supabase
          .from('notifications')
          .select('id')
          .eq('type', 'extra_hours_offer')
          .contains('data', { reservation_id: reservation.id, milestone: '30min' })
          .limit(1)
          .then(({ data: existing }) => {
            if (existing && existing.length > 0) return;
            supabase.from('notifications').insert([{
              user_id: reservation.client_id,
              type: 'extra_hours_offer',
              title: '⏰ Quedan 30 minutos',
              body: `El evento termina pronto. ¿Quieres agregar más tiempo? Desde $${pricePerHour.toLocaleString()}/hr.`,
              data: { reservation_id: reservation.id, price_per_hour: pricePerHour, milestone: '30min' },
            }]);
          });
      }
    }
  }, [elapsed, isRunning]);

  // Avisos de descanso (por empezar / por terminar): server-side desde sql/419
  // — cron notify-break-transitions cada minuto, espejo event_break_boundaries.

  // Inicio de hora extra: server-side desde sql/421 (break_ended numerada
  // "🔥 ¡La hora extra N inició!") — cron notify-break-transitions.

  const fetchPayoutInfo = async () => {
    const { data } = await supabase
      .from('reservations')
      .select('payout_status, payment_status, payout_completed')
      .eq('id', reservation.id)
      .single();
    if (data) setPayoutInfo(data as any);
  };

  useEffect(() => { if (!readOnly || userRole === 'talent') fetchPayoutInfo(); }, []);

  // Cargar coordenadas del evento — exactas (pagado) o ciudad aproximada (sin pago)
  useEffect(() => {
    const paid = isPaid(reservation.payment_status);
    const load = async () => {
      if (reservation.quote_id) {
        const { data } = await supabase
          .from('quotes')
          .select('latitude, longitude, event_municipio, event_estado')
          .eq('id', reservation.quote_id)
          .single();
        if (data) {
          if (paid && data.latitude && data.longitude) {
            setEventLatLng({ lat: data.latitude, lng: data.longitude });
            return;
          }
          const city = data.event_municipio ?? data.event_estado ?? 'guadalajara';
          setApproxDest(privacyOffset(reservation.quote_id, city));
          return;
        }
      }
      if (reservation.event_request_id) {
        const { data } = await supabase
          .from('event_requests')
          .select('latitude, longitude, location_city, location_municipio')
          .eq('id', reservation.event_request_id)
          .single();
        if (data) {
          if (paid && data.latitude && data.longitude) {
            setEventLatLng({ lat: data.latitude, lng: data.longitude });
            return;
          }
          const city = data.location_municipio ?? data.location_city ?? 'guadalajara';
          setApproxDest(privacyOffset(reservation.event_request_id, city));
        }
      }
    };
    load();
  }, []);

  // GPS del grupo (origen de la ruta)
  useEffect(() => {
    if (readOnly) return;
    Location.requestForegroundPermissionsAsync().then(({ status }) => {
      if (status !== 'granted') return;
      Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced })
        .then(loc => setGroupOrigin({ latitude: loc.coords.latitude, longitude: loc.coords.longitude }))
        .catch(() => {});
    });
  }, [readOnly]);

  // Construir ruta cuando cambian origen o destino
  useEffect(() => {
    const exactDest = eventLatLng ? { latitude: eventLatLng.lat, longitude: eventLatLng.lng } : null;
    const dest = exactDest ?? approxDest;
    if (!dest) return;
    const origin = groupOrigin ?? { latitude: dest.latitude + 0.015, longitude: dest.longitude + 0.01 };
    const pts = buildRoute(origin, dest);
    setRoutePts(pts);
    if (mapRef.current) {
      setTimeout(() => {
        mapRef.current?.fitToCoordinates([origin, dest], {
          edgePadding: { top: 40, right: 40, bottom: 40, left: 40 }, animated: true,
        });
      }, 600);
    }
  }, [eventLatLng, approxDest, groupOrigin]);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setCurrentUserId(data.session?.user.id ?? null);
    });
  }, []);


  // Auto-stop y auto-cobro cuando se agota el tiempo de música.
  // Gate: esperar a que extraHoursLoaded=true para evitar que el stop dispare
  // con totalMusicSecs calculado sin extras (race condition al re-entrar).
  useEffect(() => {
    // 🍽️📸🪑 sql/639: estas categorías NO cierran por tiempo — cierran con
    // el código de "servicio terminado" (botón manual). Sin este freno, al
    // cumplirse las horas contratadas este efecto llamaría finishEvent()
    // sin código una y otra vez (falla, reinicia el tick, vuelve a disparar).
    if (needsServiceCode) return;
    if (!extraHoursLoaded) return;
    if (!isRunning || !startedAt || totalMusicSecs === 0) return;
    if (musicElapsed >= totalMusicSecs) {
      if (intervalRef.current) clearInterval(intervalRef.current);
      setIsRunning(false);
      if (!readOnly && !autoFinishedRef.current) {
        autoFinishedRef.current = true;
        finishEvent();
      } else {
        startRatingFlow();
      }
    }
  }, [musicElapsed, totalMusicSecs, isRunning, startedAt, extraHoursLoaded, needsServiceCode]);

  const startTick = (from: Date) => {
    if (intervalRef.current) clearInterval(intervalRef.current);
    intervalRef.current = setInterval(() => {
      const diff = Math.floor((Date.now() - from.getTime()) / 1000);
      setElapsed(diff);
    }, 1000);
  };

  // [Fix 2026-09-09] Auditoría de temporizador/avisos: los `setInterval`
  // de RN se congelan o se atrasan mucho tiempo en segundo plano (según
  // plataforma/OS). Sin esto, "elapsed" solo se recalculaba hasta el
  // siguiente tick natural al volver a primer plano — normalmente
  // insignificante, pero si el tick llevaba mucho tiempo suspendido,
  // recalcular YA (en vez de esperar) reduce la ventana en la que un
  // aviso de tiempo (15 min / 2h / 30 min) puede quedar sin dispararse
  // por encontrar el temporizador ya "congelado" al reabrir la app.
  // No reemplaza los avisos de descanso (esos ya son 100% servidor).
  useEffect(() => {
    const sub = AppState.addEventListener('change', (next) => {
      if (next === 'active' && isRunning && startedAt) {
        setElapsed(Math.floor((Date.now() - startedAt.getTime()) / 1000));
        startTick(startedAt);
      }
    });
    return () => sub.remove();
  }, [isRunning, startedAt]);

  // ── Solicitar horas extra con Stripe (PASO A: solo INSERT, no paga aún) ──
  // El grupo debe aceptar primero. El pago ocurre en handlePayNow.
  // Trigger trg_notify_extra_hour_proposed (sql/395) notifica al grupo automáticamente.
  const handleRequestWithStripe = async (hours: number, price: number, msiMonths: number) => {
    if (stripeLoading) return;
    // Fail-closed: sin resCurrency confirmado, no se crea el registro financiero.
    // Nunca se asume MXN — ver auditoría de horas extra en USD.
    if (!resCurrency) {
      Alert.alert('Un momento', 'Confirmando datos de la reserva. Intenta de nuevo en unos segundos.');
      return;
    }
    setStripeLoading(true);
    try {
      const { data: existing } = await supabase
        .from('extra_hours')
        .select('id')
        .eq('reservation_id', reservation.id)
        .in('status', ['awaiting_group_confirmation', 'pending_payment', 'pending'])
        .limit(1)
        .maybeSingle();
      if (existing) {
        Alert.alert('Solicitud pendiente', 'Ya tienes una solicitud de hora extra en proceso.');
        return;
      }
      const commissionAmt = Math.round(price * 0.10 * 100) / 100;
      const ownerEarnings = price - commissionAmt;
      const { error: insertErr } = await supabase.from('extra_hours').insert([{
        reservation_id:       reservation.id,
        hours_added:          hours,
        price_per_hour:       Math.round(price / hours),
        total_extra_cost:     price,
        platform_commission:  commissionAmt,
        group_extra_earnings: ownerEarnings,
        status:               'awaiting_group_confirmation',
        payment_method:       'stripe',
        msi_months:           msiMonths,
        currency_code:        resCurrency,
      }]);
      if (insertErr) { Alert.alert('Error', 'No se pudo crear la solicitud. Intenta de nuevo.'); return; }
      setClientPendingExtra({ hours, price });
    } catch (err: any) {
      Alert.alert('Error', err.message ?? 'Intenta de nuevo.');
    } finally {
      setStripeLoading(false);
    }
  };

  // ── Pagar horas extra ya aceptadas (PASO C: Stripe PaymentSheet) ───────
  // Se llama desde el banner "Paga ahora" cuando status='pending_payment'.
  const handlePayNow = async (extraId: string, hours: number, price: number, msiMonths: number) => {
    if (stripeLoading) return;
    setStripeLoading(true);
    try {
      const { data: sd } = await supabase.auth.getSession();
      console.log('[PayNow] token ok:', !!sd.session?.access_token, '| extraId:', extraId, '| msi:', msiMonths);
      const { data: piData, error: piErr } = await supabase.functions.invoke(
        'create-extra-hour-payment-intent',
        {
          body: { extra_hour_id: extraId, msi_months: msiMonths },
          headers: { Authorization: `Bearer ${sd.session?.access_token}` },
        },
      );
      // No loguear piData completo: contiene el client_secret de Stripe
      console.log('[PayNow] Edge fn → piErr:', piErr?.message ?? 'none', '| ok:', !!piData?.client_secret);
      if (piErr) throw new Error(`Error de pago: ${piErr.message}`);
      if (!piData?.client_secret) throw new Error(piData?.error ?? 'Sin respuesta del servidor.');

      const { error: initErr } = await initPaymentSheet({
        paymentIntentClientSecret: piData.client_secret,
        merchantDisplayName: 'Daricefy',
        style: 'alwaysDark',
      });
      console.log('[PayNow] initPaymentSheet → initErr:', initErr?.message ?? 'none');
      if (initErr) throw new Error(initErr.message);

      const { error: payErr } = await presentPaymentSheet();
      console.log('[PayNow] presentPaymentSheet → code:', payErr?.code ?? 'ok', '| msg:', (payErr as any)?.message ?? 'none');
      if (payErr) {
        if (payErr.code !== 'Canceled') {
          const msg: string = (payErr as any).message ?? '';
          if (msiMonths > 1 && (msg.toLowerCase().includes('installment') || msg.toLowerCase().includes('no está disponible'))) {
            throw new Error('Esta tarjeta no es compatible con MSI. Contacta a soporte o elige 1 pago.');
          }
          throw new Error(msg || 'Ocurrió un problema al procesar el pago.');
        }
        return;
      }
      setPendingPaymentExtra(null);
      Alert.alert('¡Pago exitoso!', 'Tu pago fue recibido. El grupo fue notificado y el timer se actualizará automáticamente.');
    } catch (err: any) {
      Alert.alert('Error al procesar el pago', err.message ?? 'Intenta de nuevo.');
    } finally {
      setStripeLoading(false);
    }
  };

  // ── Actions ────────────────────────────────────────────────────────────
  const handleStartPress = () => {
    if (!breakType) {
      setPendingStartAfterBreak(true);
      setShowBreakModal(true);
      return;
    }
    setArrivalCodeInput(['', '', '', '']);
    setShowArrivalCodeModal(true);
    setTimeout(() => codeRef0.current?.focus(), 350);
  };

  const _doStartFlow = () => {
    if (breakType === 'D') {
      // sql/639: para Comida/Fotografía/renta de cosas físicas no hay
      // horas fijas que "contar" — el copy de siempre ("contarán las X
      // horas seguidas") ya no aplica, cierran con el código de servicio
      // terminado cuando de verdad acaben.
      Alert.alert(
        '⚠️ Sin descansos programados',
        needsServiceCode
          ? 'Este tipo de servicio no maneja tandas ni descansos. Cuando terminen, pide al cliente el código de "servicio terminado" para cerrar el evento. ¿Confirmas que están listos?'
          : `Este tipo de servicio no maneja tandas ni descansos — contarán las ${contractHours} horas seguidas desde que inicien. ¿Confirmas que están listos?`,
        [
          { text: 'Cancelar', style: 'cancel' },
          { text: 'Sí, iniciar', onPress: () => confirmStart() },
        ],
      );
      return;
    }
    confirmStart();
  };

  const confirmStart = async (autoBreakType?: string) => {
    const effectiveBreakType = autoBreakType ?? breakType;
    setLoading(true);
    const opt = BREAK_OPTIONS.find(o => o.type === effectiveBreakType) ?? BREAK_OPTIONS[1];
    const minsBreak = opt.breakMinutesFor(contractHours);
    const minsMusic = contractHours * 60 - minsBreak;
    if (!breakType) setBreakType(opt.type);

    // El ancla del cronómetro (event_started_at) la fija el reloj del
    // SERVIDOR (NOW() dentro del RPC), no el celular del grupo — así
    // grupo/cliente/talento calculan el tiempo transcurrido contra el
    // mismo punto de referencia real, sin depender de que el celular
    // del grupo tenga la hora bien puesta.
    const { data: startRes, error: startErr } = await supabase.rpc('start_event', {
      p_reservation_id: reservation.id,
      p_break_type: opt.type,
      p_music_minutes: minsMusic,
    });
    if (startErr || !startRes?.ok) {
      setLoading(false);
      Alert.alert('No se pudo iniciar el evento', 'Intenta de nuevo en unos segundos.');
      return;
    }
    const startTime = new Date(startRes.event_started_at);

    if (reservation.client_id) {
      await supabase.from('notifications').insert([{
        user_id: reservation.client_id,
        type: 'reservation',
        title: '🎵 ¡Tu evento ha iniciado!',
        body: `El grupo ha comenzado a tocar en tu evento del ${reservation.event_date}. ¡Disfruta!`,
        data: { reservation_id: reservation.id },
      }]);
    }

    // Integrantes/talentos también se enteran del arranque (recibían
    // llegada/descansos/fin pero no el inicio — auditoría 2026-07-12)
    const startMembersToNotify = groupMemberIds.filter(uid => uid !== currentUserId);
    if (startMembersToNotify.length > 0) {
      supabase.from('notifications').insert(
        startMembersToNotify.map(uid => ({
          user_id: uid,
          type: 'reservation',
          title: '🎵 ¡El evento inició!',
          body: 'El temporizador está corriendo. ¡A tocar!',
          data: { reservation_id: reservation.id },
        }))
      ).then();
    }

    // Modelo A: NO se libera pago al inicio. El 100% se transfiere al finalizar.
    setLoading(false);
    setStartedAt(startTime);
    setIsRunning(true);
    startTick(startTime);
  };

  const openMap = () => {
    if (eventLatLng) {
      Linking.openURL(`https://www.google.com/maps/search/?api=1&query=${eventLatLng.lat},${eventLatLng.lng}`);
    } else if (reservation.address) {
      Linking.openURL(`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(reservation.address)}`);
    }
  };

  const _doArriveFlow = async (lat: number | null, lng: number | null) => {
    // El RPC marca group_arrived_at atómicamente (candado GPS server-side,
    // sql/467) — SOLO verificación; el pago completo se libera al finalizar.
    const { data: rel, error: relErr } = await supabase.rpc('release_half_on_arrival', {
      p_reservation_id: reservation.id,
      p_lat: lat,
      p_lng: lng,
    });
    if (relErr || !rel?.ok) {
      const code: string = rel?.error ?? '';
      if (code === 'too_far') {
        Alert.alert(
          '🚩 Aún estás lejos del evento',
          `Estás a ~${formatDist((rel?.distance_m ?? 0) / 1000)} del lugar. Acércate a menos de ${ARRIVAL_RADIUS_M} m para confirmar tu llegada.`,
        );
      } else if (code === 'gps_required') {
        Alert.alert('📍 Activa tu ubicación', 'Necesitamos verificar que estás en el lugar del evento. Intenta de nuevo.');
      } else {
        Alert.alert('No se pudo registrar la llegada', 'Intenta de nuevo en unos segundos.');
      }
      return;
    }
    console.log('[Arrival] Llegada verificada — el pago completo se libera al finalizar.');

    const ts = new Date().toISOString();
    setHasArrived(true);
    setArrivedAt(ts);

    // Obtener client_id desde DB si no viene en el objeto
    let clientId: string | null = reservation.client_id ?? null;
    if (!clientId) {
      const { data: res } = await supabase
        .from('reservations')
        .select('client_id')
        .eq('id', reservation.id)
        .single();
      clientId = res?.client_id ?? null;
    }

    // Notificar al cliente
    if (clientId) {
      const { error: notifErr } = await supabase.from('notifications').insert([{
        user_id: clientId,
        type: 'reservation',
        title: '📍 El grupo ha llegado',
        body: 'El grupo ya llegó al lugar del evento. ¡Todo listo para comenzar!',
        data: { reservation_id: reservation.id },
      }]);
      if (notifErr) console.warn('Notification insert error:', notifErr.message);
    }

    // Notificar a todos los admins
    const { data: admins } = await supabase
      .from('profiles')
      .select('id')
      .eq('role', 'admin');

    if (admins && admins.length > 0) {
      const clientName = reservation.client?.full_name ?? 'Cliente';
      await supabase.from('notifications').insert(
        admins.map((admin: any) => ({
          user_id: admin.id,
          type: 'reservation',
          title: '📍 Grupo llegó al evento',
          body: `El grupo llegó al evento del cliente ${clientName} en ${reservation.address ?? 'dirección no especificada'}. Fecha: ${reservation.event_date}`,
          data: { reservation_id: reservation.id },
        }))
      );
    }

    // Notificar a integrantes del grupo — excluye al owner (quien presionó el botón)
    const membersToNotify = groupMemberIds.filter(uid => uid !== currentUserId);
    if (membersToNotify.length > 0) {
      supabase.from('notifications').insert(
        membersToNotify.map(uid => ({
          user_id: uid,
          type: 'reservation',
          title: '📍 El dueño llegó al evento',
          body: 'Se confirmó la llegada al lugar. Coordínense para el inicio.',
          data: { reservation_id: reservation.id },
        }))
      ).then();
    }

    Alert.alert('¡Llegada registrada!', 'Se notificó al cliente que ya llegaste.');
  };

  const handleArrivePress = async () => {
    if (arriving) return;   // evita doble-tap mientras se resuelve el GPS
    // 🔒 Igual que "Voy en camino": la llegada solo se marca el DÍA del
    // evento (antes se podía apretar días antes — bug 2026-07-16)
    if (!isEventDay) {
      Alert.alert('🗓️ Aún no es el día', 'Podrás marcar tu llegada el día del evento.');
      return;
    }
    // Sin coords del evento (reserva directa): el server libera con
    // arrival_gps_verified=false y avisa al admin — flujo sin GPS.
    if (!eventLatLng) {
      Alert.alert(
        '¿Ya llegaste al lugar?',
        'Esto notificará al cliente que ya estás en el evento.',
        [
          { text: 'Cancelar', style: 'cancel' },
          { text: 'Sí, llegué', onPress: () => _doArriveFlow(null, null) },
        ]
      );
      return;
    }

    // Evento con coords: verificación GPS obligatoria antes de marcar llegada
    const { status } = await Location.requestForegroundPermissionsAsync();
    if (status !== 'granted') {
      Alert.alert(
        '📍 Activa tu ubicación',
        'Para confirmar tu llegada necesitamos verificar que estás en el lugar del evento. Activa el permiso de ubicación e intenta de nuevo.',
        [
          { text: 'Abrir Ajustes', onPress: () => Linking.openSettings() },
          { text: 'Cancelar', style: 'cancel' },
        ]
      );
      return;
    }

    // Feedback inmediato: obtener un fix GPS de alta precisión puede tardar
    // varios segundos. Mostramos "Verificando…" al instante para que el botón
    // no parezca muerto mientras se resuelve la ubicación.
    setArriving(true);
    let pos: Location.LocationObject;
    try {
      pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.High });
    } catch {
      setArriving(false);
      Alert.alert(
        'No pudimos obtener tu ubicación',
        'Revisa que el GPS esté activado y vuelve a intentar en unos segundos.',
      );
      return;
    }
    setArriving(false);

    const distM = haversineKm(
      pos.coords.latitude, pos.coords.longitude,
      eventLatLng.lat, eventLatLng.lng,
    ) * 1000;
    if (distM > ARRIVAL_RADIUS_M) {
      Alert.alert(
        '🚩 Aún estás lejos del evento',
        `Estás a ~${formatDist(distM / 1000)} del lugar. Acércate a menos de ${ARRIVAL_RADIUS_M} m para confirmar tu llegada.`,
      );
      return;
    }

    Alert.alert(
      '¿Ya llegaste al lugar?',
      'Esto notificará al cliente que ya estás en el evento.',
      [
        { text: 'Cancelar', style: 'cancel' },
        { text: 'Sí, llegué', onPress: () => _doArriveFlow(pos.coords.latitude, pos.coords.longitude) },
      ]
    );
  };

  // Auto-avance entre cajas + backspace
  const handleCodeDigit = (text: string, index: number) => {
    const digit = text.replace(/[^0-9]/g, '').slice(-1);
    const next = [...arrivalCodeInput];
    next[index] = digit;
    setArrivalCodeInput(next);
    if (digit && index < 3) {
      [codeRef0, codeRef1, codeRef2, codeRef3][index + 1].current?.focus();
    }
  };

  const handleCodeKeyPress = (key: string, index: number) => {
    if (key === 'Backspace' && !arrivalCodeInput[index] && index > 0) {
      [codeRef0, codeRef1, codeRef2, codeRef3][index - 1].current?.focus();
    }
  };

  const handleCodeSubmit = async () => {
    const code = arrivalCodeInput.join('');
    if (code.length < 4) return;
    setCodeLoading(true);
    const { data, error } = await supabase.rpc('validate_start_code', {
      p_reservation_id: reservation.id,
      p_code: code,
    });
    setCodeLoading(false);
    if (error || !data?.ok) {
      Alert.alert('Código inválido', data?.error ?? 'Verifica el código con el cliente e intenta de nuevo.');
      setArrivalCodeInput(['', '', '', '']);
      setTimeout(() => codeRef0.current?.focus(), 100);
      return;
    }
    setShowArrivalCodeModal(false);
    _doStartFlow();
  };

  // ── Código de "servicio terminado" (sql/639) — mismo patrón que el de
  //    llegada, pero cierra el evento directo en vez de arrancarlo.
  const handleServiceCodeDigit = (text: string, index: number) => {
    const digit = text.replace(/[^0-9]/g, '').slice(-1);
    const next = [...serviceCodeInput];
    next[index] = digit;
    setServiceCodeInput(next);
    if (digit && index < 3) {
      [svcCodeRef0, svcCodeRef1, svcCodeRef2, svcCodeRef3][index + 1].current?.focus();
    }
  };

  const handleServiceCodeKeyPress = (key: string, index: number) => {
    if (key === 'Backspace' && !serviceCodeInput[index] && index > 0) {
      [svcCodeRef0, svcCodeRef1, svcCodeRef2, svcCodeRef3][index - 1].current?.focus();
    }
  };

  const handleServiceCodeSubmit = async () => {
    const code = serviceCodeInput.join('');
    if (code.length < 4) return;
    setServiceCodeLoading(true);
    const result = await finishEvent(code);
    setServiceCodeLoading(false);
    if (result?.invalidCode) {
      Alert.alert('Código inválido', 'Verifica el código con el cliente e intenta de nuevo.');
      setServiceCodeInput(['', '', '', '']);
      setTimeout(() => svcCodeRef0.current?.focus(), 100);
      return;
    }
    if (result?.ok) {
      setShowServiceCodeModal(false);
    }
  };

  // serviceCode: solo para las categorías de sql/639 (Comida, Fotografía,
  // renta de mesas/sillas/brincolines/inflables, Drones, cabinas) — el
  // código de "servicio terminado" que el cliente le da al proveedor.
  // Para las demás categorías se llama sin argumento, como siempre.
  const finishEvent = async (serviceCode?: string) => {
    if (intervalRef.current) clearInterval(intervalRef.current);
    setIsRunning(false);
    setLoading(true);
    let succeeded = false;

    try {
      // Fix 1+3: capturar resultado — NO proceder si complete_event falla
      const { data: completeData, error: completeError } = await supabase.rpc('complete_event', {
        p_reservation_id: reservation.id,
        ...(serviceCode ? { p_service_code: serviceCode } : {}),
      });

      if (completeError || completeData?.ok === false) {
        // Código de servicio incorrecto: el evento sigue en curso, se deja
        // que quien llamó (el modal de código) muestre su propio aviso y
        // permita reintentar, en vez del genérico de abajo.
        if (completeData?.error === 'invalid_service_code') {
          setIsRunning(true);
          if (startedAt) startTick(startedAt);
          return { ok: false, invalidCode: true };
        }
        Alert.alert('Error al finalizar', 'No se pudo registrar el fin del evento. Intenta de nuevo.');
        setIsRunning(true);
        if (startedAt) startTick(startedAt);
        return { ok: false };
      }

      // 🔒 Registro de horarios — mensaje de seguridad (petición del
      // usuario 2026-09-10): que el proveedor sepa que quedó guardada la
      // hora de inicio y fin, como respaldo si algo se disputa después.
      if (completeData?.note !== 'already_completed' && startedAt) {
        const endLabel = new Date(completeData?.completed_at ?? Date.now())
          .toLocaleTimeString('es-MX', { hour: 'numeric', minute: '2-digit' });
        const startLabel = startedAt.toLocaleTimeString('es-MX', { hour: 'numeric', minute: '2-digit' });
        Alert.alert(
          '✅ Evento finalizado',
          `Inició a las ${startLabel} y terminó a las ${endLabel}. Guardamos este registro para tu seguridad, por si algo se disputa después.`,
        );
      }

      // Fix 3: release SOLO después de confirmar éxito de complete_event
      supabase.rpc('release_group_earnings_atomic', { p_reservation_id: reservation.id })
        .then(({ data, error }) => {
          if (error) console.warn('[FinishEvent] Error liberando ganancias:', error.message);
          else if (data?.amount_released) {
            console.log('[FinishEvent] Ganancias liberadas:', data.amount_released);
          }
        });

      // Liberar ganancias de horas extra (50% restante o 100% si partial no corrió)
      supabase.rpc('release_extra_hours_final', { p_reservation_id: reservation.id })
        .then(({ data, error }) => {
          if (error) console.warn('[FinishEvent] Error liberando extras:', error.message);
          else if (data?.amount > 0) {
            console.log('[FinishEvent] Extras liberados:', data.amount);
          }
        });

      try { await fetchPayoutInfo(); } catch (e) { console.warn('[FinishEvent] fetchPayoutInfo:', e); }

      // Recargar payouts para la pantalla de celebración
      try {
        const { data: freshPayouts } = await supabase
          .from('event_payouts')
          .select('id, user_id, role, amount, payout_status, profile:user_id(full_name)')
          .eq('reservation_id', reservation.id);
        if (freshPayouts) setPayouts(freshPayouts as any);
      } catch (e) { console.warn('[FinishEvent] event_payouts:', e); }

      // Notif: evento finalizado → cliente + dueño del grupo
      const finishNotifs: any[] = [];
      if (reservation.client_id) {
        finishNotifs.push({
          user_id: reservation.client_id,
          type: 'event_finalized',
          title: '🎉 ¡Tu evento ha terminado!',
          body: `¿Cómo estuvo ${reservation.group?.name ?? 'el grupo'}? Deja tu calificación.`,
          data: { reservation_id: reservation.id, target_screen: 'EventTimer' },
        });
      }
      // BUG F: reservation.group?.owner_id puede ser undefined si la navegación no
      // incluye el join de grupos (ej. GroupEventsScreen). ownerIdRef es un ref
      // (no state) para evitar el stale closure del auto-stop useEffect.
      const ownerIdForNotif = reservation.group?.owner_id ?? ownerIdRef.current ?? null;
      if (ownerIdForNotif) {
        finishNotifs.push({
          user_id: ownerIdForNotif,
          type: 'event_finalized',
          title: '✅ Evento finalizado',
          body: 'El evento ha concluido. Tu pago se liberará en breve.',
          data: { reservation_id: reservation.id, target_screen: 'EventTimer' },
        });
      }
      // Talentos invitados — excluir al owner para no duplicar
      groupMemberIds
        .filter(id => id !== ownerIdForNotif)
        .forEach(talentId => {
          finishNotifs.push({
            user_id: talentId,
            type: 'event_finalized',
            title: '✅ Evento finalizado',
            body: 'El evento ha concluido. Revisa tus ganancias en la app.',
            data: { reservation_id: reservation.id, target_screen: 'EventTimer' },
          });
        });
      // [Fix 2026-09-09] complete_event() es idempotente (devuelve
      // ok:true, note:'already_completed' si ya estaba cerrado — p.ej. la
      // pantalla se remontó justo cuando este flujo ya había terminado
      // antes). Sin este check, un segundo llamado a finishEvent() volvía
      // a mandar "¡Tu evento ha terminado!" duplicado a cliente/grupo.
      if (finishNotifs.length > 0 && completeData?.note !== 'already_completed') {
        await supabase.from('notifications').insert(finishNotifs);
      }

      succeeded = true;
      return { ok: true };
    } catch (err) {
      console.warn('[FinishEvent] Error general:', err);
      Alert.alert('Error inesperado', 'Ocurrió un error al finalizar el evento. Intenta de nuevo.');
      setIsRunning(true);
      if (startedAt) startTick(startedAt);
      return { ok: false };
    } finally {
      setLoading(false);
      if (succeeded) startRatingFlow();
    }
  };


  // ── Rating queue helpers ─────────────────────────────────────────────────
  const startRatingFlow = async () => {
    if (hasAlreadyRated) { return; }
    const queue: RatingSubject[] = [];

    if (!readOnly) {
      // Dueño del grupo: califica al cliente
      if (reservation.client_id) {
        queue.push({
          type: 'client',
          targetId: reservation.client_id,
          targetName: reservation.client?.full_name ?? 'el cliente',
          reservationId: reservation.id,
        });
      }
      // Dueño del grupo: califica SOLO a talentos invitados por tocada (job invitations)
      // Los miembros permanentes del grupo NO se califican aquí
      invitedTalents
        .filter(t => t.status === 'accepted' && t.profile)
        .forEach(t => {
          queue.push({
            type: 'talent',
            targetId: (t as any).invited_user_id ?? t.id,
            targetName: t.profile?.full_name ?? 'Talento',
            reservationId: reservation.id,
          });
        });
    } else if (userRole === 'client') {
      // Cliente: califica al grupo — de paso trae el país del grupo (no
      // viene en `reservation.group`) para poder abrir el modal de
      // propina (GiftPickerModal) con la moneda correcta.
      const { data: grp } = await supabase
        .from('groups').select('country').eq('id', reservation.group_id).single();
      queue.push({
        type: 'group',
        targetId: reservation.group_id,
        targetName: reservation.group?.name ?? 'el grupo',
        reservationId: reservation.id,
        groupCountry: grp?.country ?? null,
      });
    }

    if (queue.length > 0) {
      setRatingQueue(queue.slice(1));
      setCurrentRating(queue[0]);
    }
    // Si queue vacía (rol talent u otro sin targets): quedarse en vista completada
  };

  const advanceRatingQueue = (submitted: { stars: number; comment: string } | null) => {
    const justSubmitted = currentRating;

    // Enviar notificación review_received por cada submit (no en skip)
    if (justSubmitted && submitted) {
      const notifs: any[] = [];
      const starsText = `${submitted.stars} estrella${submitted.stars !== 1 ? 's' : ''}`;

      if (justSubmitted.type === 'group') {
        // Cliente calificó al grupo → notificar al dueño del grupo
        const ownerName = reservation.client?.full_name ?? 'El cliente';
        if (reservation.group?.owner_id) {
          notifs.push({
            user_id: reservation.group.owner_id,
            type: 'review_received',
            title: '⭐ Recibiste una calificación',
            body: `${ownerName} te calificó con ${starsText}`,
            data: { reservation_id: reservation.id, review_type: 'cliente_a_grupo', target_screen: 'EventTimer' },
          });
        }
        // Talentos del grupo
        groupMemberIds.filter(id => id !== reservation.group?.owner_id).forEach(id => {
          notifs.push({
            user_id: id,
            type: 'review_received',
            title: '⭐ El cliente calificó el evento',
            body: `${ownerName} calificó el evento con ${starsText}`,
            data: { reservation_id: reservation.id, review_type: 'cliente_a_grupo', target_screen: 'EventTimer' },
          });
        });
      } else if (justSubmitted.type === 'client') {
        // Grupo calificó al cliente → notificar al cliente
        const groupName = reservation.group?.name ?? 'El grupo';
        if (reservation.client_id) {
          notifs.push({
            user_id: reservation.client_id,
            type: 'review_received',
            title: '⭐ Recibiste una calificación',
            body: `${groupName} te calificó con ${starsText}`,
            data: { reservation_id: reservation.id, review_type: 'grupo_a_cliente', target_screen: 'EventTimer' },
          });
        }
        // Talentos del grupo
        groupMemberIds.filter(id => id !== currentUserId).forEach(id => {
          notifs.push({
            user_id: id,
            type: 'review_received',
            title: '⭐ El grupo calificó al cliente',
            body: `${groupName} calificó a ${reservation.client?.full_name ?? 'el cliente'}`,
            data: { reservation_id: reservation.id, review_type: 'grupo_a_cliente', target_screen: 'EventTimer' },
          });
        });
      } else if (justSubmitted.type === 'talent') {
        // Grupo calificó a un talento específico
        notifs.push({
          user_id: justSubmitted.targetId,
          type: 'review_received',
          title: '⭐ Recibiste una calificación',
          body: `${reservation.group?.name ?? 'El grupo'} te calificó con ${starsText}`,
          data: { reservation_id: reservation.id, review_type: 'grupo_a_talento', target_screen: 'EventTimer' },
        });
      }

      if (notifs.length > 0) {
        void supabase.from('notifications').insert(notifs.filter(n => n.user_id));
      }
    }

    if (ratingQueue.length > 0) {
      setCurrentRating(ratingQueue[0]);
      setRatingQueue(prev => prev.slice(1));
    } else {
      setCurrentRating(null);
      setHasAlreadyRated(true);
      // Re-fetch la review que ME dieron (para mostrar tarjeta verde)
      void (async () => {
        const { data: sessionData } = await supabase.auth.getSession();
        const myUserId = sessionData?.session?.user.id ?? '';
        let receivedData: { rating: number; comment: string | null; created_at: string } | null = null;
        if (userRole === 'client') {
          const { data } = await supabase.from('client_reviews')
            .select('rating, comment, created_at')
            .eq('reservation_id', reservation.id).limit(1);
          receivedData = data?.[0] ?? null;
        } else if (userRole === 'talent') {
          const { data } = await supabase.from('talent_reviews')
            .select('rating, comment, created_at')
            .eq('reservation_id', reservation.id)
            .eq('talent_id', myUserId).limit(1);
          receivedData = data?.[0] ?? null;
        } else {
          const { data } = await supabase.from('reviews')
            .select('rating, comment, created_at')
            .eq('reservation_id', reservation.id).limit(1);
          receivedData = data?.[0] ?? null;
        }
        if (receivedData) {
          setReviewReceived({
            rating: receivedData.rating,
            comment: receivedData.comment ?? undefined,
            createdAt: receivedData.created_at ?? undefined,
          });
        }
      })();
    }
  };

  // ── Derived state ──────────────────────────────────────────────────────
  const progress   = totalMusicSecs > 0 ? Math.min(musicElapsed / totalMusicSecs, 1) : 0;
  const isOnBreak  = currentSegment?.type === 'break';
  // True when event is over — covers both live completion (startedAt set) and
  // fresh loads of already-completed reservations (startedAt may still be null).
  const isCompleted = !isRunning && (
    (!!startedAt && musicElapsed >= totalMusicSecs) ||
    reservation.status === 'completed' ||
    !!reservation.event_ended_at
  );

  // Pulso del punto "●" en el banner EN VIVO (solo cuando corre y no está en descanso)
  useEffect(() => {
    if (isRunning && !isOnBreak) {
      const anim = Animated.loop(
        Animated.sequence([
          Animated.timing(pulseAnim, { toValue: 1.5, duration: 900, useNativeDriver: true }),
          Animated.timing(pulseAnim, { toValue: 1.0, duration: 900, useNativeDriver: true }),
        ])
      );
      anim.start();
      return () => { anim.stop(); pulseAnim.setValue(1); };
    } else {
      pulseAnim.setValue(1);
    }
  }, [isRunning, isOnBreak]);


  const time = splitTime(remaining);
  const elapsedTime = splitTime(elapsed);
  const timePercent = totalMusicSecs > 0 ? remaining / totalMusicSecs : 1;

  // When completed, show actual event duration instead of 00:00:00
  const finalElapsedSeconds = (() => {
    if (reservation?.event_ended_at && reservation?.event_started_at) {
      return Math.max(0, Math.floor(
        (new Date(reservation.event_ended_at).getTime() - new Date(reservation.event_started_at).getTime()) / 1000
      ));
    }
    return elapsed > 0 ? elapsed : totalMusicSecs;
  })();
  const displayTime = isCompleted ? splitTime(finalElapsedSeconds) : time;
  const ringColor = isCompleted
    ? COLORS.muted
    : isOnBreak
      ? COLORS.orange
      : timePercent < 0.1
        ? '#FF5252'
        : timePercent < 0.25
          ? COLORS.orange
          : COLORS.green;
  // Offset del arco SVG: 0 = anillo completo, RING_CIRC = anillo vacío
  const svgDashOffset = totalMusicSecs > 0
    ? RING_CIRC * Math.min(musicElapsed / totalMusicSecs, 1)
    : 0;

  // Transición suave de color del ring (800ms al cruzar umbral)
  const colorPhase = isCompleted ? 3
    : isOnBreak ? 1
    : timePercent < 0.1 ? 2
    : timePercent < 0.25 ? 1
    : 0;
  useEffect(() => {
    if (colorPhase === ringColorPhaseRef.current) return;
    ringColorPhaseRef.current = colorPhase;
    Animated.timing(ringColorAnim, {
      toValue: colorPhase,
      duration: 800,
      useNativeDriver: false,
    }).start();
  }, [colorPhase]);
  const animatedRingColor = ringColorAnim.interpolate({
    inputRange: [0, 1, 2, 3],
    outputRange: [COLORS.green, COLORS.orange, '#FF5252', COLORS.muted],
  });

  // ── Helpers para CircleTimerVisual ───────────────────────────────────────
  // Hora extra REAL: segmento de música posterior al tiempo base contratado
  // (mismo criterio que la notificación de inicio de hora extra)
  const isInExtraSegment = isRunning
    && currentSegment?.type === 'music'
    && currentSegment.fromMin >= contractHours * 60;
  const getTimerVisualState = (): TimerState => {
    if (isCompleted) return 'completed';
    if (isOnBreak) return 'break';
    if (isInExtraSegment) return 'extra_hours';
    if (isRunning) return 'live';
    return 'pre_event';
  };
  // Hora de inicio en 12h a partir de event_time crudo (tolera "8:00"/"20:00"),
  // o 'Hoy' si el evento no tiene hora fija (exprés). Nunca un guión.
  const eventStartLabel = (() => {
    if (!rawEventTime) return 'Hoy';
    const [hStr, mStr] = rawEventTime.split(':');
    const hh = parseInt(hStr, 10);
    if (isNaN(hh)) return 'Hoy';
    const ampm = hh >= 12 ? 'PM' : 'AM';
    const h12  = hh % 12 || 12;
    return `${h12}:${(mStr ?? '00').substring(0, 2).padStart(2, '0')} ${ampm}`;
  })();

  const getTimerSubtitle = (): string => {
    if (isCompleted) return `${contractHours + extraHoursAdded}h tocadas`;
    if (isOnBreak && currentSegment) {
      const bSecs = Math.max(0, currentSegment.toMin * 60 - elapsed);
      const bm = Math.floor(bSecs / 60);
      const bs = bSecs % 60;
      return `Vuelves en ${bm}:${String(bs).padStart(2, '0')}`;
    }
    if (isInExtraSegment) return `+${extraHoursAdded}h extra activa`;
    // Pre-evento: el número grande es la cuenta regresiva → el subtítulo da
    // la hora. Si NO hay conteo (el número ya muestra la hora), subtítulo
    // vacío para no repetirla dos veces.
    if (!startedAt) {
      return (preEventCountdown && eventStartLabel !== 'Hoy') ? `🕐 ${eventStartLabel}` : '';
    }
    if (isRunning) {
      // 🍽️📸🪑 sql/639: "Restan Xh Ym" es engañoso aquí — no hay una hora
      // fija que esperar, cierran con el código de servicio terminado.
      if (needsServiceCode) return 'Cierra con código, no por tiempo';
      const h = Math.floor(remaining / 3600);
      const m = Math.floor((remaining % 3600) / 60);
      return `Restan ${h}h ${m}m`;
    }
    return '';
  };

  return (
    <View style={st.container}>
      <SafeAreaView style={{ flex: 1 }}>
        <View style={st.header}>
          <Pressable style={st.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <View style={{ alignItems: 'center' }}>
            <Text style={st.headerTitle}>Temporizador</Text>
            {reservation.event_date && (
              <Text style={st.headerSub}>
                {new Date(reservation.event_date + 'T12:00:00').toLocaleDateString('es-MX', { weekday: 'short', day: 'numeric', month: 'short' })}
              </Text>
            )}
          </View>
        </View>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={st.scroll}>

          {/* ── BANNER "PAGA AHORA" — grupo aceptó con Stripe ── */}
          {userRole === 'client' && pendingPaymentExtra && (
            <View style={st.payNowBanner}>
              <Text style={st.payNowBannerTitle}>
                ✅ Grupo aceptó tus +{pendingPaymentExtra.hours}h
              </Text>
              <Text style={st.payNowBannerSub}>
                Total: ${pendingPaymentExtra.price.toLocaleString()} MXN
                {pendingPaymentExtra.msiMonths > 1 ? ` · ${pendingPaymentExtra.msiMonths} meses` : ''}
              </Text>
              <Pressable
                style={[st.payNowBannerBtn, stripeLoading && { opacity: 0.6 }]}
                disabled={stripeLoading}
                onPress={() => handlePayNow(
                  pendingPaymentExtra.id,
                  pendingPaymentExtra.hours,
                  pendingPaymentExtra.price,
                  pendingPaymentExtra.msiMonths,
                )}
              >
                {stripeLoading
                  ? <ActivityIndicator color="#FFFFFF" size="small" />
                  : <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                      <CreditCard size={15} color="#FFFFFF" />
                      <Text style={st.payNowBannerBtnText}>Pagar ahora</Text>
                    </View>
                }
              </Pressable>
              <Text style={st.payNowBannerTimer}>⏱ Tienes 20 min para confirmar el pago</Text>
            </View>
          )}

          {/* ── TIMER (siempre visible para todos) ──────────── */}
          <View style={st.timerSection}>

            {/* ── STATE BANNER — legible de reojo a 2 metros ─── */}
            {(() => {
              if (!startedAt && !isCompleted) {
                const label = !hasArrived ? '⏱  WARMUP' : '⏱  WARMUP · ✓ Llegaste';
                return (
                  <View style={st.bannerWarmup}>
                    <Text style={st.bannerWarmupText}>{label}</Text>
                  </View>
                );
              }
              if (isOnBreak && currentSegment) {
                const bSecs = Math.max(0, currentSegment.toMin * 60 - elapsed);
                const bm = Math.floor(bSecs / 60);
                const bs = bSecs % 60;
                return (
                  <View style={st.bannerBreak}>
                    <Text style={st.bannerBreakText}>⏸  EN DESCANSO</Text>
                    <Text style={st.bannerBreakSub}>
                      Vuelves en {bm}:{String(bs).padStart(2, '0')}
                    </Text>
                  </View>
                );
              }
              if (readOnly && clientPendingExtra && isRunning) {
                return (
                  <View style={st.bannerPendingExtra}>
                    <Text style={st.bannerPendingExtraText}>⏳ +{clientPendingExtra.hours}h solicitada</Text>
                    <Text style={st.bannerPendingExtraSub}>El grupo está revisando</Text>
                  </View>
                );
              }
              if (isRunning) {
                return (
                  <View style={st.bannerLive}>
                    <Text style={st.bannerLiveText}>▶  EN VIVO</Text>
                    <Animated.Text style={[st.bannerDot, { transform: [{ scale: pulseAnim }] }]}>
                      ●
                    </Animated.Text>
                  </View>
                );
              }
              return null;
            })()}

            {/* Timer visual premium — 5 estados animados */}
            <CircleTimerVisual
              state={getTimerVisualState()}
              currentTime={
                getTimerVisualState() === 'pre_event'
                  ? (preEventCountdown || eventStartLabel)
                  : `${String(displayTime.h).padStart(2, '0')}:${String(displayTime.m).padStart(2, '0')}:${String(displayTime.s).padStart(2, '0')}`
              }
              subtitle={getTimerSubtitle()}
              progress={isCompleted ? 1 : progress}
              size={RING_SIZE}
            />

            {/* 🍽️📸🪑 Aclaración (sql/639, 2026-09-10) — el círculo sigue
                mostrando tiempo transcurrido de forma informativa, pero para
                estas categorías NO hace falta esperar a que se complete.
                Solo Texto nuevo, no toca CircleTimerVisual ni su lógica. */}
            {!readOnly && needsServiceCode && isRunning && (
              <Text style={st.serviceCodeHint}>
                No necesitas esperar a que el círculo se complete — toca{' '}
                <Text style={{ fontFamily: FONTS.bodySemiBold, color: COLORS.green }}>
                  "Marcar como terminado"
                </Text>{' '}
                en cuanto de verdad acaben.{'\n'}
                Sí es necesario cerrarlo: así queda el registro de cuándo
                iniciaron y terminaron, para tu seguridad.
              </Text>
            )}
          </View>

          {/* ── OFRECER HORAS EXTRA (grupo dueño, solo durante evento activo).
                 Oculto si hay otra tocada después ese día — no hay tiempo. ── */}
          {!readOnly && isRunning && !isOnBreak && extraHoursCap > 0 && (
            <Pressable
              style={({ pressed }) => [st.extraSmallBtn, pressed && { opacity: 0.8 }]}
              onPress={() => navigation.navigate('ExtraHours', { reservation, maxExtra: extraHoursCap })}
            >
              <Text style={{ fontSize: 13 }}>🎵</Text>
              <Text style={st.extraSmallBtnTx}>Ofrecer horas extra</Text>
            </Pressable>
          )}

          {/* ── TARJETA DE CALIFICACIÓN recibida ── */}
          {isCompleted && reviewReceived && (() => {
            const reviewerName = (userRole === 'client' || userRole === 'talent')
              ? (reservation.group?.name ?? 'el grupo')
              : (reservation.client?.full_name ?? 'el cliente');
            return (
              <View style={st.reviewCard}>
                <View style={st.reviewStarsRow}>
                  {[1, 2, 3, 4, 5].map(n => (
                    <Text key={n} style={n <= reviewReceived.rating ? st.reviewStarOn : st.reviewStarOff}>★</Text>
                  ))}
                </View>
                {!!reviewReceived.comment && (
                  <Text style={st.reviewCommentInline}>
                    {reviewReceived.comment}
                  </Text>
                )}
                <Text style={st.reviewCardFooter}>
                  — De {reviewerName}{reviewReceived.createdAt ? ` · ${timeAgo(reviewReceived.createdAt)}` : ''}
                </Text>
              </View>
            );
          })()}

          {/* ── ROLE CONTEXT STRIP ──────────────────────────────── */}
          <View style={st.roleContextStrip}>
            {/* Left: info de la OTRA parte (no del que está viendo) */}
            <View style={st.roleContextLeft}>
              {!readOnly && reservation.client?.full_name ? (
                // Dueño del grupo → ve info del CLIENTE
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
                  <View style={st.clientAvatarBox}>
                    {reservation.client.avatar_url ? (
                      <Image source={{ uri: reservation.client.avatar_url }} style={st.clientAvatarImg} />
                    ) : (
                      <Text style={st.clientAvatarInitial}>
                        {reservation.client.full_name.charAt(0).toUpperCase()}
                      </Text>
                    )}
                  </View>
                  <View>
                    <Text style={st.roleContextLabel} numberOfLines={1}>{reservation.client.full_name}</Text>
                    <Text style={st.roleContextSub}>Cliente</Text>
                  </View>
                </View>
              ) : (userRole === 'client' || userRole === 'talent') && reservation.group?.name ? (
                // Cliente o Talento → ve info del GRUPO (con foto si viene en el parámetro)
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
                  <View style={st.clientAvatarBox}>
                    {(reservation.group as any)?.profile_image ? (
                      <Image source={{ uri: (reservation.group as any).profile_image }} style={st.clientAvatarImg} />
                    ) : (
                      <Text style={st.clientAvatarInitial}>
                        {reservation.group.name.charAt(0).toUpperCase()}
                      </Text>
                    )}
                  </View>
                  <View>
                    <Text style={st.roleContextLabel} numberOfLines={1}>{reservation.group.name}</Text>
                    <Text style={st.roleContextSub}>Grupo</Text>
                  </View>
                </View>
              ) : null}
            </View>
            {/* Right: contracted hours */}
            <View style={st.roleContextRight}>
              <Text style={st.roleContextHours}>{contractHours}h</Text>
              <Text style={st.roleContextHoursLabel}>contratadas</Text>
            </View>
          </View>

          {/* ── BREAK INFO + SCHEDULE ──────────────────────────── */}
          {breakType ? (
            <View style={st.breakCard}>
              <Text style={st.breakInfoText}>
                {breakType === 'D'
                  ? '🎵 Tocarán corrido, sin descansos'
                  : breakType === 'A'
                  ? '☕ Descanso de 15 min después de cada hora tocada'
                  : '☕ Un descanso de 15 min a la mitad del evento'}
              </Text>
              {!readOnly && userRole !== 'talent' && !isRunning && !startedAt && (
                <Pressable onPress={() => setShowBreakModal(true)}>
                  <Text style={st.changeBreak}>Cambiar tipo de descanso →</Text>
                </Pressable>
              )}

              {/* Timeline */}
              {schedule.length > 0 && (() => {
                const elapsedMin = elapsed / 60;
                // Bug 1: cuando hay extras aceptadas, forzar elapsed a inicio del bloque extra
                // para que todos los segmentos originales aparezcan como "pasados".
                const extraStartMin = contractHours * 60;
                const effectiveElapsedMin = extraHoursAdded > 0
                  ? Math.max(elapsedMin, extraStartMin + 0.1)
                  : elapsedMin;
                return (
                  <View style={st.scheduleSection}>
                    <Text style={st.scheduleTitle}>Horario del evento</Text>
                    {schedule.map((seg, i) => {
                      const isActive = effectiveElapsedMin >= seg.fromMin && effectiveElapsedMin < seg.toMin;
                      const isPast = effectiveElapsedMin >= seg.toMin;
                      const isExtra = seg.isExtra ?? false;
                      return (
                        <View key={i} style={[
                          st.scheduleRow,
                          // Bug 2: color del fondo activo según tipo (break=azul, music extra=dorado, music orig=verde)
                          isActive
                            ? (seg.type === 'break'
                                ? st.scheduleRowActiveBreak
                                : (isExtra ? st.scheduleRowExtraActive : st.scheduleRowActive))
                            : (isExtra
                                ? (isPast ? st.scheduleRowExtraPast : st.scheduleRowExtra)
                                : (isPast ? st.scheduleRowPast : undefined)),
                        ]}>
                          <View style={[
                            st.scheduleIcon,
                            isExtra ? st.scheduleIconExtra
                              : (seg.type === 'break' ? st.scheduleIconBreak : st.scheduleIconMusic),
                            // Ícono activo: break=azul, música extra=dorado, música orig=verde
                            isActive && (
                              seg.type === 'break'
                                ? st.scheduleIconBreakActive
                                : isExtra
                                  ? st.scheduleIconExtraActive
                                  : st.scheduleIconMusicActive
                            ),
                          ]}>
                            {seg.type === 'music'
                              ? <Music2 size={14} color={isActive ? COLORS.bg : (isExtra ? '#FBBF24' : isPast ? COLORS.muted : COLORS.green)} />
                              : <Coffee size={14} color={isActive ? COLORS.bg : (isExtra ? '#FBBF24' : isPast ? COLORS.muted : '#60A5FA')} />
                            }
                          </View>
                          <View style={{ flex: 1 }}>
                            <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
                              <Text style={[st.scheduleLabel, isExtra ? st.scheduleLabelExtra : isPast && st.scheduleLabelPast]}>
                                {isPast && !isExtra ? '✓ ' : ''}
                                {seg.type === 'music' ? 'Tocando' : 'Descanso'}
                                {isActive && !isExtra && (seg.type === 'music' ? ' 🎵' : ' ☕')}
                              </Text>
                              {isExtra && (
                                <View style={st.scheduleBadgeExtra}>
                                  <Text style={st.scheduleBadgeExtraText}>Hora extra</Text>
                                </View>
                              )}
                            </View>
                            <Text style={[st.scheduleTime, isExtra ? st.scheduleTimeExtra : isPast && st.scheduleTimePast]}>
                              {seg.fromTime} — {seg.toTime}
                            </Text>
                          </View>
                          <Text style={[st.scheduleDuration, isExtra ? st.scheduleDurationExtra : isPast && st.scheduleTimePast]}>
                            {seg.toMin - seg.fromMin} min
                          </Text>
                        </View>
                      );
                    })}
                  </View>
                );
              })()}
            </View>
          ) : (
            !readOnly && userRole !== 'talent' && !startedAt && (
              <Pressable style={st.selectBreakBtn} onPress={() => setShowBreakModal(true)}>
                <Clock size={16} color={COLORS.green} />
                <Text style={st.selectBreakText}>Seleccionar tipo de descanso</Text>
              </Pressable>
            )
          )}

          {/* ── STATUS ────────────────────────────────────────── */}
          <View style={st.statusRow}>
            {isRunning ? (
              <Badge label={isOnBreak ? '☕ En descanso' : '🎵 En progreso'} variant={isOnBreak ? 'blue' : 'green'} dot />
            ) : isCompleted ? (
              <Badge label="✅ Completado" variant="muted" />
            ) : startedAt ? (
              <Badge label="✅ Completado" variant="muted" />
            ) : (
              <Badge label="⏳ Sin iniciar" variant="orange" />
            )}
          </View>

          {/* ── EVENT INFO ─────────────────────────────────────── */}
          <View style={st.infoCard}>
            {eventFolio && (
              <Text style={st.folioChip}>{eventFolio}</Text>
            )}
            {/* ❓ Guía del evento — mismo flujo para ambos, cada quien sus pasos */}
            <Pressable
              style={st.guideLink}
              hitSlop={8}
              onPress={() => navigation.navigate('EventGuide', {
                role: (userRole === 'client') ? 'client' : 'group',
              })}
            >
              <Text style={st.guideLinkTx}>❓ ¿Cómo funciona el evento?</Text>
            </Pressable>
            <View style={st.infoRow}>
              <Clock size={15} color={COLORS.muted2} />
              <Text style={st.infoText}>
                {reservation.event_time
                ? `Inicio: ${formatTime12h(reservation.event_time)}`
                : 'Hora no especificada'}
              </Text>
            </View>
            <View style={st.infoRow}>
              <MapPin size={15} color={COLORS.muted2} />
              <Text style={[st.infoText, { flex: 1 }]} numberOfLines={2}>{reservation.address}</Text>
            </View>
            {(reservation.address || eventLatLng) && (
              <Pressable style={st.mapBtn} onPress={openMap}>
                <Navigation size={14} color={COLORS.green} />
                <Text style={st.mapBtnText}>Abrir en Google Maps</Text>
                <ExternalLink size={12} color={COLORS.green} />
              </Pressable>
            )}
            {/* Mapa Express-style — zona aprox antes de pago, ruta+partículas al pagar */}
            {!readOnly && (eventLatLng || approxDest) && (
              <View style={st.exactMapWrap}>
                <Text style={st.exactMapLabel}>
                  {isPaid(reservation.payment_status) ? '📍 Ubicación exacta del cliente' : '📍 Zona aproximada del evento'}
                </Text>
                <MapView
                  ref={mapRef}
                  style={st.exactMap}
                  provider={PROVIDER_GOOGLE}
                  customMapStyle={EARTH_STYLE}
                  userInterfaceStyle="dark"
                  initialRegion={eventLatLng
                    ? { latitude: eventLatLng.lat, longitude: eventLatLng.lng, latitudeDelta: 0.018, longitudeDelta: 0.018 }
                    : approxDest
                    ? { latitude: approxDest.latitude, longitude: approxDest.longitude, latitudeDelta: 0.018, longitudeDelta: 0.018 }
                    : undefined}
                  scrollEnabled={true}
                  zoomEnabled={true}
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
                  {/* Círculo zona aprox (siempre visible) */}
                  {(approxDest || eventLatLng) && (
                    <MapCircle
                      center={eventLatLng ? { latitude: eventLatLng.lat, longitude: eventLatLng.lng } : approxDest!}
                      radius={isPaid(reservation.payment_status) ? 60 : 450}
                      fillColor="rgba(0,230,118,0.06)"
                      strokeColor="rgba(0,230,118,0.35)"
                      strokeWidth={1.5}
                    />
                  )}
                  {/* Ruta verde (solo pagado) — opaco para no mezclar con azul del mapa */}
                  {isPaid(reservation.payment_status) && routePts.length > 1 && (
                    <Polyline coordinates={routePts} strokeWidth={3} strokeColor="#00E676" />
                  )}
                  {/* Instrumentos viajando del grupo al cliente */}
                  {isPaid(reservation.payment_status) && routePts.length > 1 && (
                    <>
                      <RouteParticle route={routePts} delay={0}    emoji="🎸" />
                      <RouteParticle route={routePts} delay={1333} emoji="🎺" />
                      <RouteParticle route={routePts} delay={2666} emoji="🎻" />
                    </>
                  )}
                  {/* Marcador destino */}
                  {(eventLatLng || approxDest) && (
                    <Marker
                      coordinate={eventLatLng
                        ? { latitude: eventLatLng.lat, longitude: eventLatLng.lng }
                        : approxDest!}
                      anchor={{ x: 0.5, y: 0.5 }}
                      tracksViewChanges={false}
                    >
                      <DestPinMarker />
                    </Marker>
                  )}
                  {/* Punto de origen del grupo */}
                  {isPaid(reservation.payment_status) && groupOrigin && (
                    <Marker coordinate={groupOrigin} anchor={{ x: 0.5, y: 0.5 }} tracksViewChanges={false}>
                      <View style={etMapSt.originDot}><View style={etMapSt.originInner} /></View>
                    </Marker>
                  )}
                </MapView>
              </View>
            )}
          </View>

          {/* ── SOPORTE: siempre visible durante el evento ── */}
          <Pressable
            style={st.supportRow}
            hitSlop={8}
            onPress={() => openSupport(eventFolio ? `el evento ${eventFolio}` : undefined)}
          >
            <Text style={st.supportRowText}>💬 ¿Necesitas ayuda? Contacta a soporte</Text>
          </Pressable>


          {/* ── PUNTUALIDAD: banner pre-evento (solo grupo) ── */}
          {!readOnly && !startedAt && !isCompleted && reservation.event_date && reservation.event_time && (
            <View style={st.punctualityBanner}>
              <Text style={st.punctualityIcon}>⏰</Text>
              <View style={{ flex: 1 }}>
                <Text style={st.punctualityTitle}>Puedes iniciar antes, no después</Text>
                <Text style={st.punctualitySub}>
                  {`El evento es a las ${formatTime12h(reservation.event_time)}.\nPara iniciar, pide al cliente su código de inicio.\nSin el código no puedes comenzar antes.\n⏰ Si pasan 15 min del horario sin código, el evento inicia automáticamente.`}
                </Text>
              </View>
            </View>
          )}

          {/* ── ACTIONS ─────────────────────────────────────────── */}
          {readOnly ? (
            <>
              {/* Banner de llegada del grupo (visible para cliente) */}
              {userRole === 'client' && hasArrived && !startedAt && (
                <View style={st.arrivedBanner}>
                  <View style={st.arrivedIconWrap}>
                    <Text style={{ fontSize: 24 }}>📍</Text>
                  </View>
                  <View style={{ flex: 1 }}>
                    <Text style={st.arrivedTitle}>¡El grupo ya llegó!</Text>
                    <Text style={st.arrivedSub}>
                      El grupo está en el lugar y listo para comenzar.
                      {arrivedAt ? ` Llegaron a las ${new Date(arrivedAt).toLocaleTimeString('es-MX', { hour: '2-digit', minute: '2-digit' })}.` : ''}
                    </Text>
                  </View>
                </View>
              )}
              {/* Para integrantes del grupo: banner de observador */}
              {userRole === 'talent' && (
                <View style={st.readOnlyBanner}>
                  <View style={st.readOnlyIconWrap}>
                    <Text style={{ fontSize: 22 }}>🎵</Text>
                  </View>
                  <View style={{ flex: 1 }}>
                    <Text style={st.readOnlyText}>Observando en vivo</Text>
                    <Text style={st.readOnlyHint}>El dueño del grupo controla el temporizador. Tu presencia está registrada.</Text>
                  </View>
                </View>
              )}
            </>
          ) : (
            <View style={st.actions}>
              {/* (a) Pre-llegada, pre-inicio */}
              {!isRunning && !startedAt && !hasArrived && (
                <>
                  {/* 🚐 En camino — el cliente ve al grupo acercándose en su mapa */}
                  <Pressable
                    style={({ pressed }) => [st.iconBtn, st.iconBtnOutline, enRoute && { opacity: 0.75 }, !isEventDay && { opacity: 0.45 }, pressed && !enRoute && { opacity: 0.8 }]}
                    onPress={startEnRoute}
                    disabled={enRoute}
                  >
                    <Text style={{ fontSize: 17 }}>🚐</Text>
                    <Text style={[st.iconBtnLabel, { color: enRoute ? COLORS.green : '#000' }]}>
                      {enRoute ? 'En camino — el cliente te ve acercarte'
                        : isEventDay ? 'Voy en camino'
                        : 'Voy en camino (el día del evento)'}
                    </Text>
                  </Pressable>
                  <View style={{ height: 10 }} />
                  <Pressable
                    style={({ pressed }) => [st.iconBtn, st.iconBtnPrimary, arriving && st.iconBtnDisabled, pressed && !arriving && { opacity: 0.8 }]}
                    onPress={handleArrivePress}
                    disabled={arriving}
                  >
                    {arriving ? (
                      <>
                        <ActivityIndicator color={COLORS.black} size="small" />
                        <Text style={[st.iconBtnLabel, { color: COLORS.black }]}>Verificando ubicación…</Text>
                      </>
                    ) : (
                      <>
                        <MapPin size={18} color={COLORS.black} />
                        <Text style={[st.iconBtnLabel, { color: COLORS.black }]}>Llegué al evento</Text>
                      </>
                    )}
                  </Pressable>
                  <View style={{ height: 10 }} />
                  {eventTargetMs != null && !canStartNow && (
                    <Text style={st.autoStartHint}>
                      {'⏳ Auto-inicio a las ' + (() => {
                        const g = new Date(eventTargetMs + 10 * 60 * 1000);
                        return g.toLocaleTimeString('es-MX', { hour: '2-digit', minute: '2-digit' });
                      })() + ' si no inicias antes'}
                    </Text>
                  )}
                  <Pressable
                    style={({ pressed }) => [
                      st.iconBtn, st.iconBtnOutline,
                      (!canStartNow || loading) && st.iconBtnDisabled,
                      pressed && !(!canStartNow || loading) && { opacity: 0.8 },
                    ]}
                    onPress={handleStartPress}
                    disabled={!canStartNow || loading}
                  >
                    {loading
                      ? <ActivityIndicator color={COLORS.green} size="small" />
                      : <>
                          <Play size={18} color={!canStartNow ? COLORS.muted : COLORS.green} />
                          <Text style={[st.iconBtnLabel, { color: !canStartNow ? COLORS.muted : COLORS.green }]}>
                            Iniciar evento
                          </Text>
                        </>
                    }
                  </Pressable>
                </>
              )}
              {/* (b) Post-llegada, pre-inicio */}
              {!isRunning && !startedAt && hasArrived && (
                <>
                  {eventTargetMs != null && !canStartNow && (
                    <Text style={st.autoStartHint}>
                      {'⏳ Auto-inicio a las ' + (() => {
                        const g = new Date(eventTargetMs + 10 * 60 * 1000);
                        return g.toLocaleTimeString('es-MX', { hour: '2-digit', minute: '2-digit' });
                      })() + ' si no inicias antes'}
                    </Text>
                  )}
                  <Pressable
                    style={({ pressed }) => [
                      st.iconBtn, st.iconBtnPrimary,
                      (!canStartNow || loading) && st.iconBtnDisabled,
                      pressed && !(!canStartNow || loading) && { opacity: 0.8 },
                    ]}
                    onPress={handleStartPress}
                    disabled={!canStartNow || loading}
                  >
                    {loading
                      ? <ActivityIndicator color={COLORS.black} size="small" />
                      : <>
                          <Play size={18} color={COLORS.black} />
                          <Text style={[st.iconBtnLabel, { color: COLORS.black }]}>Iniciar evento</Text>
                        </>
                    }
                  </Pressable>
                </>
              )}
              {/* (c/d) EN VIVO o EN DESCANSO */}
              {isRunning && (
                <>
                  {!hasArrived && (
                    <>
                      <Pressable
                        style={({ pressed }) => [st.iconBtn, st.iconBtnOutline, (arriving || !isEventDay) && st.iconBtnDisabled, pressed && !arriving && isEventDay && { opacity: 0.8 }]}
                        onPress={handleArrivePress}
                        disabled={arriving}
                      >
                        {arriving ? <ActivityIndicator color={COLORS.green} size="small" /> : <MapPin size={18} color={COLORS.green} />}
                        <Text style={[st.iconBtnLabel, { color: COLORS.green }]}>
                          {arriving ? 'Verificando ubicación…' : isEventDay ? 'Llegué al evento' : 'Llegué al evento (el día del evento)'}
                        </Text>
                      </Pressable>
                      <View style={{ height: 10 }} />
                    </>
                  )}
                  {/* Sin finalización manual para el resto de categorías: el
                      evento termina SOLO cuando se cumple el tiempo
                      (auto-stop) — decisión de producto 2026-07-12.
                      Emergencias las resuelve el admin. */}
                  {/* 🍽️📸🪑 Comida/Fotografía/renta de cosas físicas (sql/639,
                      2026-09-10): sin duración predecible, así que aquí SÍ hay
                      botón manual — pide el código nuevo que el cliente les
                      da cuando de verdad terminaron. */}
                  {needsServiceCode && hasArrived && (
                    <>
                      <View style={{ height: 10 }} />
                      <Pressable
                        style={({ pressed }) => [st.iconBtn, st.iconBtnPrimary, loading && st.iconBtnDisabled, pressed && !loading && { opacity: 0.8 }]}
                        onPress={() => setShowServiceCodeModal(true)}
                        disabled={loading}
                      >
                        <CheckCircle size={18} color={COLORS.black} />
                        <Text style={[st.iconBtnLabel, { color: COLORS.black }]}>Marcar como terminado</Text>
                      </Pressable>
                    </>
                  )}
                </>
              )}
            </View>
          )}

          {/* ── HORAS EXTRA — cliente solicita (últimos 15 min) ── */}
          {userRole === 'client' && isRunning && nearEnd && clientExtraOpts.length > 0 && extraHoursAdded === 0 && !pendingPaymentExtra && (
            <>
              {/* Anti-bypass warning */}
              <View style={st.antiBypassBanner}>
                <Text style={st.antiBypassText}>
                  ⚠️ Para tu seguridad y garantía de servicio, solicita tus horas extra aquí, a través de la app. Los pagos fuera de la plataforma no están cubiertos por nuestra garantía de calidad.
                </Text>
              </View>

              <View style={st.clientExtraCard}>
                <Text style={st.clientExtraTitle}>¿Quieres más tiempo? 🎵</Text>
                <Text style={st.clientExtraSub}>Solicita horas extra con tarjeta — el grupo confirma y el anillo se actualiza automáticamente.</Text>

                {clientPendingExtra ? (
                  <View style={st.clientExtraPending}>
                    <Text style={st.clientExtraPendingIcon}>⏳</Text>
                    <Text style={st.clientExtraPendingText}>
                      Solicitud de +{clientPendingExtra.hours}h enviada al grupo.{'\n'}Esperando confirmación…
                    </Text>
                  </View>
                ) : (
                  <View style={st.clientExtraOpts}>
                    {clientExtraOpts.map(opt => (
                      <Pressable
                        key={opt.hours}
                        style={[
                          st.clientExtraOpt,
                          extraHoursAdded >= opt.hours && st.clientExtraOptDone,
                        ]}
                        onPress={() => {
                          if (extraHoursAdded >= opt.hours) return;
                          setMsiPendingChoice({ hours: opt.hours, price: opt.price });
                          setMsiSelectedMonths(1);
                          setShowMsiModal(true);
                        }}
                      >
                        <Text style={st.clientExtraOptHours}>+{opt.hours}h</Text>
                        <Text style={st.clientExtraOptPrice}>${opt.price.toLocaleString()}</Text>
                        {extraHoursAdded >= opt.hours && (
                          <Text style={st.clientExtraOptDoneLabel}>✓ Activo</Text>
                        )}
                      </Pressable>
                    ))}
                  </View>
                )}
              </View>
            </>
          )}

          {/* espacio para el FAB */}
          {(hasArrived || isRunning) && !reservation.event_ended_at && (
            <View style={{ height: 80 }} />
          )}

          {/* ── TALENTOS INVITADOS ──────────────────────────────── */}
          {invitedTalents.length > 0 && (
            <View style={st.extraSection}>
              <Text style={st.extraSectionTitle}>🎸 Talentos invitados</Text>
              {invitedTalents.map(t => (
                <View key={t.id} style={st.talentRow}>
                  <View style={st.talentAvatar}>
                    <Text style={st.talentAvatarText}>
                      {(t.profile as any)?.full_name?.charAt(0)?.toUpperCase() ?? '?'}
                    </Text>
                  </View>
                  <Text style={st.talentName} numberOfLines={1}>
                    {(t.profile as any)?.full_name ?? 'Talento'}
                  </Text>
                  <View style={[st.talentChip, {
                    borderColor: t.status === 'accepted' ? COLORS.green : COLORS.muted,
                  }]}>
                    <Text style={[st.talentChipText, {
                      color: t.status === 'accepted' ? COLORS.green : COLORS.muted,
                    }]}>
                      {t.status === 'accepted' ? '✅ Confirmado' : '⏳ Pendiente'}
                    </Text>
                  </View>
                </View>
              ))}
            </View>
          )}

          {/* ── DETALLES DEL EVENTO (grupo + talento) ───────────── */}
          {false && canSeeDetails && (
            <>
              {false && (
                <View style={st.detailsSection}>

                  {/* ── Detalles completos de la cotización ── */}
                  <View style={st.clientReqCard}>
                    <Text style={st.clientReqTitle}>Detalles del evento</Text>

                    {reservation.client?.full_name && (
                      <View style={st.clientReqRow}>
                        <Text style={st.clientReqLabel}>Cliente</Text>
                        <Text style={st.clientReqValue}>{reservation.client.full_name}</Text>
                      </View>
                    )}
                    {reservation.event_date && (
                      <View style={st.clientReqRow}>
                        <Text style={st.clientReqLabel}>Fecha</Text>
                        <Text style={st.clientReqValue}>
                          {new Date(reservation.event_date + 'T12:00:00').toLocaleDateString('es-MX', {
                            weekday: 'short', day: 'numeric', month: 'short', year: 'numeric',
                          })}
                        </Text>
                      </View>
                    )}
                    {reservation.event_time && (
                      <View style={st.clientReqRow}>
                        <Text style={st.clientReqLabel}>Hora de inicio</Text>
                        <Text style={st.clientReqValue}>{formatTime12h(reservation.event_time)}</Text>
                      </View>
                    )}
                    {(reservation.quote?.event_type || reservation.event_type) && (
                      <View style={st.clientReqRow}>
                        <Text style={st.clientReqLabel}>Tipo de evento</Text>
                        <Text style={st.clientReqValue}>{reservation.quote?.event_type ?? reservation.event_type}</Text>
                      </View>
                    )}
                    {(reservation.quote?.guests_count ?? reservation.guests_count) != null && (
                      <View style={st.clientReqRow}>
                        <Text style={st.clientReqLabel}>Invitados</Text>
                        <Text style={st.clientReqValue}>{reservation.quote?.guests_count ?? reservation.guests_count} personas</Text>
                      </View>
                    )}
                    {reservation.address ? (
                      <View style={st.clientReqRow}>
                        <Text style={st.clientReqLabel}>Lugar</Text>
                        <Text style={[st.clientReqValue, { flex: 2 }]} numberOfLines={2}>{reservation.address}</Text>
                      </View>
                    ) : null}
                    <View style={st.clientReqRow}>
                      <Text style={st.clientReqLabel}>Horas contratadas</Text>
                      <Text style={st.clientReqValue}>{contractHours}h</Text>
                    </View>
                    {breakType ? (
                      <View style={st.clientReqRow}>
                        <Text style={st.clientReqLabel}>Tipo de descanso</Text>
                        <Text style={st.clientReqValue}>{selectedBreak?.label ?? breakType}</Text>
                      </View>
                    ) : null}
                    {/* Horas extra pactadas */}
                    {reservation.quote?.overtime_1h_price != null && (
                      <View style={st.clientReqRow}>
                        <Text style={st.clientReqLabel}>Hora extra (1h)</Text>
                        <Text style={[st.clientReqValue, { color: COLORS.green }]}>
                          ${reservation.quote.overtime_1h_price.toLocaleString()}
                        </Text>
                      </View>
                    )}
                    {reservation.quote?.overtime_2h_price != null && (
                      <View style={st.clientReqRow}>
                        <Text style={st.clientReqLabel}>Hora extra (2h)</Text>
                        <Text style={[st.clientReqValue, { color: COLORS.green }]}>
                          ${reservation.quote.overtime_2h_price.toLocaleString()}
                        </Text>
                      </View>
                    )}
                    {reservation.quote?.overtime_3h_price != null && (
                      <View style={st.clientReqRow}>
                        <Text style={st.clientReqLabel}>Hora extra (3h)</Text>
                        <Text style={[st.clientReqValue, { color: COLORS.green }]}>
                          ${reservation.quote.overtime_3h_price.toLocaleString()}
                        </Text>
                      </View>
                    )}
                    {/* Notas / requerimientos */}
                    {(reservation.quote?.notes || reservation.notes) ? (
                      <View style={[st.clientReqRow, { flexDirection: 'column', alignItems: 'flex-start', gap: 6 }]}>
                        <Text style={st.clientReqLabel}>Notas y requerimientos</Text>
                        <Text style={[st.clientReqValue, { textAlign: 'left', color: COLORS.text, lineHeight: 20 }]}>
                          {reservation.quote?.notes ?? reservation.notes}
                        </Text>
                      </View>
                    ) : null}
                  </View>

                  {/* ── Distribución de ganancias — SOLO "Tu ganancia" (regla:
                        el grupo nunca ve el total del cliente ni comisiones) ── */}
                  <View style={st.commissionBox}>
                    <Text style={st.clientReqTitle}>Distribución de ganancias</Text>

                    {/* Ganancia neta del grupo */}
                    <View style={[st.commRow, st.commNetRow]}>
                      <Text style={st.commNetLabel}>Ganancia del grupo</Text>
                      <Text style={st.commNetValue}>
                        ${(reservation.group_earnings ?? (reservation.total_price != null ? reservation.total_price - (reservation.commission_amount ?? 0) : null))?.toLocaleString() ?? '—'}
                      </Text>
                    </View>

                    {/* Reparto sugerido equitativo */}
                    {payouts.length > 0 && (() => {
                      const groupNetAmt = reservation.group_earnings
                        ?? (reservation.total_price != null ? reservation.total_price - (reservation.commission_amount ?? Math.round(reservation.total_price * 0.10)) : 0);
                      const perPerson   = Math.round((groupNetAmt / payouts.length) * 100) / 100;
                      return (
                        <>
                          <Text style={st.commMemberTitle}>💡 Reparto sugerido equitativo</Text>
                          {payouts.map(p => {
                            const roleLabel =
                              p.role === 'owner'  ? 'Dueño del grupo' :
                              p.role === 'member' ? 'Integrante' : 'Invitado';
                            return (
                              <View key={p.id} style={st.memberDistRow}>
                                <View style={{ flex: 1 }}>
                                  <Text style={st.memberDistName} numberOfLines={1}>
                                    {(p.profile as any)?.full_name ?? 'Usuario'}
                                  </Text>
                                  <Text style={st.memberDistRole}>{roleLabel}</Text>
                                </View>
                                <Text style={[st.memberDistAmount, { color: COLORS.green }]}>
                                  ${perPerson.toLocaleString()}
                                </Text>
                              </View>
                            );
                          })}
                          <Text style={[st.memberDistRole, { marginTop: 6, fontSize: 11, color: COLORS.muted2 }]}>
                            El dueño del grupo gestiona la distribución por fuera de la plataforma.
                          </Text>
                        </>
                      );
                    })()}
                  </View>

                  {/* ── Estado de pago y cartera ── */}
                  {(!readOnly || userRole === 'talent') && (
                    <View style={st.stripePayoutBox}>
                      <View style={st.stripePayoutRow}>
                        {isPaid(payoutInfo.payment_status)
                          ? <CheckCircle size={15} color={COLORS.green} />
                          : <Clock size={15} color={COLORS.muted2} />}
                        <View style={{ flex: 1 }}>
                          <Text style={[st.stripePayoutLabel, isPaid(payoutInfo.payment_status) && st.stripePayoutLabelDone]}>
                            {isPaid(payoutInfo.payment_status) ? 'Pago completo recibido' : 'Esperando confirmación de pago'}
                          </Text>
                        </View>
                      </View>
                      <View style={st.stripePayoutDivider} />
                      <View style={st.stripePayoutRow}>
                        {payoutInfo.payout_status === 'released'
                          ? <CheckCircle size={15} color={COLORS.green} />
                          : <Clock size={15} color={COLORS.muted2} />}
                        <View style={{ flex: 1 }}>
                          <Text style={[st.stripePayoutLabel, payoutInfo.payout_status === 'released' && st.stripePayoutLabelDone]}>
                            {payoutInfo.payout_status === 'released'
                              ? 'Ganancia liberada en cartera'
                              : payoutInfo.payout_status === 'held'
                                ? 'Ganancia retenida (se libera 12h post-evento)'
                                : 'Ganancia pendiente de confirmación'}
                          </Text>
                        </View>
                      </View>
                    </View>
                  )}

                </View>
              )}
            </>
          )}

        </ScrollView>

        {/* ── CHAT FAB ─────────────────────────────────────────── */}
        {!isCompleted && !startedAt && (hasArrived || isRunning) && (
          <Pressable
            style={st.chatFab}
            onPress={() => {
              setUnreadMessages(0);
              navigation.navigate('Chat', {
                reservation: { ...reservation, group_arrived_at: arrivedAt },
                senderRole: userRole === 'client' ? 'client' : 'group',
              });
            }}
          >
            <MessageCircle size={24} color={COLORS.bg} />
            {unreadMessages > 0 && (
              <View style={st.chatFabBadge}>
                <Text style={st.chatBadgeText}>
                  {unreadMessages > 99 ? '99+' : unreadMessages}
                </Text>
              </View>
            )}
          </Pressable>
        )}

      </SafeAreaView>

      {/* ── CONFIRMACIÓN DEL GRUPO: HORA EXTRA ───────────────── */}
      <Modal visible={showGroupConfirmModal} transparent animationType="slide">
        <View style={st.modalOverlay}>
          <View style={st.modal}>
            {pendingExtraRow && (() => {
              const hrs = pendingExtraRow.hours_added ?? 1;
              const total = pendingExtraRow.total_extra_cost ?? 0;
              const comm = pendingExtraRow.platform_commission ?? 0;
              const groupCut = pendingExtraRow.group_extra_earnings ?? (total - comm);
              return (
                <>
                  <Text style={st.modalTitle}>📲 Solicitud de hora extra</Text>
                  <Text style={st.modalSub}>
                    El cliente quiere agregar{' '}
                    <Text style={{ color: COLORS.green, fontFamily: FONTS.bodySemiBold }}>
                      {hrs} hora{hrs > 1 ? 's' : ''} más
                    </Text>
                    . ¿Aceptan continuar tocando?
                  </Text>

                  {/* Lo que recibe el grupo — sin mostrar comisión */}
                  <View style={st.groupEarningsBox}>
                    <Text style={st.groupEarningsLabel}>Lo que recibirías</Text>
                    <Text style={st.groupEarningsAmount}>${Math.round(groupCut).toLocaleString()}</Text>
                  </View>

                  {/* Badge método de pago */}
                  <View style={st.paymentMethodBadge}>
                    <Text style={st.paymentMethodBadgeText}>
                      {(pendingExtraRow.payment_method ?? 'balance') === 'stripe'
                        ? `💳 Tarjeta${(pendingExtraRow.msi_months ?? 1) > 1 ? ` · ${pendingExtraRow.msi_months} meses MSI` : ' · Pago único'}`
                        : '💰 Saldo del cliente'}
                    </Text>
                  </View>

                  {/* Aviso de términos — disuade cobro por fuera */}
                  <View style={st.securityNoticeGroup}>
                    <Text style={st.securityNoticeGroupText}>
                      💼 Recuerda: cobrar por fuera viola los términos de uso, pierdes respaldo legal y de pagos, y acumulas strikes automáticos.
                    </Text>
                  </View>

                  <Pressable
                    style={[st.confirmBtn, { backgroundColor: COLORS.green }]}
                    onPress={async () => {
                      // ── Validar conflicto con evento posterior del mismo grupo ──
                      if (reservation.event_time && reservation.group_id) {
                        const { data: nextEvent } = await supabase
                          .from('reservations')
                          .select('id, event_time')
                          .eq('group_id', reservation.group_id)
                          .eq('event_date', reservation.event_date)
                          .neq('id', reservation.id)
                          .in('status', ['confirmed', 'accepted'])
                          .gt('event_time', reservation.event_time)
                          .order('event_time', { ascending: true })
                          .limit(1)
                          .maybeSingle();

                        if (nextEvent?.event_time) {
                          const currentStartH = parseInt(reservation.event_time.split(':')[0], 10);
                          const newEndH = currentStartH + contractHours + extraHoursAdded + hrs;
                          const nextStartH = parseInt((nextEvent.event_time as string).split(':')[0], 10);
                          if (newEndH + 2 > nextStartH) {
                            Alert.alert(
                              'Conflicto de agenda',
                              `Estas horas extra terminarían a las ${newEndH}:00, lo que no deja el buffer mínimo de 2h antes del siguiente evento (${nextStartH}:00). No es posible aceptar.`,
                            );
                            return;
                          }
                        }
                      }

                      setShowGroupConfirmModal(false);

                      if ((pendingExtraRow.payment_method ?? 'balance') === 'stripe') {
                        // STRIPE: solo aceptar; el cliente paga después con PaymentSheet
                        const { data: result, error } = await supabase.rpc('group_accept_extra_hour_stripe', {
                          p_extra_id: pendingExtraRow.id,
                        });
                        console.log('[ACCEPT] error:', error?.message ?? 'none', '| result:', JSON.stringify(result));
                        if (error || result?.ok === false) {
                          Alert.alert('Error', 'No se pudo aceptar la solicitud. Intenta de nuevo.');
                        } else {
                          Alert.alert('✅ Solicitud aceptada', 'El cliente recibirá una notificación para completar el pago con tarjeta.');
                        }
                        setPendingExtraRow(null);
                      } else {
                        // LEGACY BALANCE: confirmar con cargo al saldo del cliente
                        const { data: confirmResult, error } = await supabase.rpc('group_confirm_extra_hours', {
                          p_extra_id: pendingExtraRow.id,
                        });
                        if (error || confirmResult?.ok === false) {
                          if (confirmResult?.error === 'saldo_insuficiente') {
                            Alert.alert(
                              'Saldo insuficiente',
                              `El cliente no tiene fondos suficientes para esta hora extra.\n\nDisponible: $${Number(confirmResult.balance ?? 0).toLocaleString()}\nRequerido:  $${Number(confirmResult.required ?? 0).toLocaleString()}\n\nLa solicitud fue cancelada y el cliente fue notificado.`
                            );
                            await supabase.rpc('group_reject_extra_hour', { p_extra_id: pendingExtraRow.id });
                          } else {
                            Alert.alert('Error', 'No se pudo confirmar. Intenta de nuevo.');
                          }
                          setPendingExtraRow(null);
                          return;
                        }
                        if (reservation.client_id) {
                          supabase.from('notifications').insert([{
                            user_id: reservation.client_id,
                            type: 'reservation',
                            title: '✅ ¡Hora extra confirmada!',
                            body: `El grupo aceptó. Se agregaron ${hrs}h extra al temporizador.`,
                            data: { reservation_id: reservation.id },
                          }]).then();
                        }
                        setExtraHoursAdded(prev => prev + hrs);
                        setPendingExtraRow(null);
                      }
                    }}
                  >
                    <Text style={st.confirmBtnText}>
                      {(pendingExtraRow.payment_method ?? 'balance') === 'stripe'
                        ? '✅ Aceptar solicitud'
                        : '✅ Aceptar y extender timer'}
                    </Text>
                  </Pressable>

                  <Pressable
                    style={[st.cancelBreakBtn, { marginTop: 8 }]}
                    onPress={async () => {
                      setShowGroupConfirmModal(false);
                      await supabase.rpc('group_reject_extra_hour', { p_extra_id: pendingExtraRow.id });
                      setPendingExtraRow(null);
                    }}
                  >
                    <Text style={st.cancelBreakBtnText}>Rechazar</Text>
                  </Pressable>
                </>
              );
            })()}
          </View>
        </View>
      </Modal>

      {/* ── MÉTODO DE COBRO DEL SALDO FINAL ──────────────────── */}
      <Modal visible={showPaymentMethodModal} transparent animationType="slide">
        <View style={st.modalOverlay}>
          <View style={st.modal}>
            <Text style={st.modalTitle}>💳 ¿Cómo cobraron el saldo?</Text>
            <Text style={st.modalSub}>
              El cobro automático no pudo procesarse. Registra cómo cobraste el saldo restante al cliente.
            </Text>
            {(['Efectivo', 'Tap to Pay', 'Transferencia'] as const).map(method => (
              <Pressable
                key={method}
                style={[st.breakOpt, { marginBottom: 8 }]}
                onPress={async () => {
                  setShowPaymentMethodModal(false);
                  await supabase.from('reservations')
                    .update({ payment_collection_method: method })
                    .eq('id', reservation.id);
                  setPaymentFailReason(paymentFailReason);
                  setPaymentPending(true);
                }}
              >
                <Text style={[st.breakOptLabel, { marginLeft: 0 }]}>
                  {method === 'Efectivo' ? '💵' : method === 'Tap to Pay' ? '📱' : '🏦'} {method}
                </Text>
              </Pressable>
            ))}
            <Pressable
              style={st.cancelBreakBtn}
              onPress={() => {
                setShowPaymentMethodModal(false);
                setPaymentPending(true);
              }}
            >
              <Text style={st.cancelBreakBtnText}>Omitir</Text>
            </Pressable>
          </View>
        </View>
      </Modal>


      {/* (El modal de "Finalizar evento" manual fue retirado — el evento
          termina automáticamente al cumplirse el tiempo contratado + extras) */}

      {/* ── PAGO PENDIENTE / COBRO FALLIDO ────────────────────── */}
      <Modal visible={paymentPending} transparent={false} animationType="fade">
        <PaymentPendingOverlay
          reason={paymentFailReason}
          onClose={() => {
            setPaymentPending(false);
            navigation.goBack();
          }}
        />
      </Modal>

      {/* ── CALIFICACIÓN POST-EVENTO ──────────────────────────── */}
      <RatingModal
        visible={!!currentRating}
        subject={currentRating}
        onDone={advanceRatingQueue}
      />

      {/* ── MODAL: TIPO DE DESCANSO ──────────────────────────── */}
      <Modal visible={showBreakModal} transparent animationType="slide">
        <View style={st.modalOverlay}>
          <View style={[st.modal, { flex: 1 }]}>
            <Text style={st.modalTitle}>Tipo de descanso</Text>
            <Text style={st.modalSub}>
              Pregunta al cliente cuál prefiere y selecciónalo aquí.{'\n'}
              El tiempo de música se actualizará automáticamente.
            </Text>

            <ScrollView style={{ flex: 1 }} showsVerticalScrollIndicator={false}>
              {BREAK_OPTIONS.map(opt => (
                <Pressable
                  key={opt.type}
                  style={[st.breakOpt, breakType === opt.type && st.breakOptActive]}
                  onPress={() => setBreakType(opt.type)}
                >
                  <View style={st.breakOptLeft}>
                    <View style={[st.breakOptRadio, breakType === opt.type && st.breakOptRadioActive]}>
                      {breakType === opt.type && <View style={st.breakOptRadioDot} />}
                    </View>
                    <View style={{ flex: 1 }}>
                      <Text style={[st.breakOptLabel, breakType === opt.type && { color: COLORS.green }]}>
                        {opt.label}
                        {!opt.clientVisible && (
                          <Text style={st.breakOptOnlyGroup}> (solo grupo)</Text>
                        )}
                      </Text>
                      <Text style={st.breakOptDesc}>{opt.desc(contractHours)}</Text>
                      {breakType === opt.type && (
                        <Text style={st.breakOptCalc}>
                          → Música: {formatMinutes(contractHours * 60 - opt.breakMinutesFor(contractHours))}
                          {' · '}Evento: {formatMinutes(opt.totalMinutes(contractHours))}
                        </Text>
                      )}
                    </View>
                  </View>
                </Pressable>
              ))}
            </ScrollView>

            <Pressable
              style={[st.confirmBtn, !breakType && { opacity: 0.4 }]}
              onPress={() => {
                setShowBreakModal(false);
                // Persist break_type to DB immediately so useFocusEffect can
                // restore it on re-mount even if the event hasn't started yet.
                if (breakType) {
                  supabase.from('reservations')
                    .update({ break_type: breakType })
                    .eq('id', reservation.id)
                    .then();
                }
                if (pendingStartAfterBreak && breakType) {
                  setPendingStartAfterBreak(false);
                  setTimeout(() => {
                    setArrivalCodeInput(['', '', '', '']);
                    setShowArrivalCodeModal(true);
                    setTimeout(() => codeRef0.current?.focus(), 350);
                  }, 350);
                }
              }}
              disabled={!breakType}
            >
              <Text style={st.confirmBtnText}>Confirmar</Text>
            </Pressable>
            <Pressable
              style={st.cancelBreakBtn}
              onPress={() => { setShowBreakModal(false); setPendingStartAfterBreak(false); }}
            >
              <Text style={st.cancelBreakBtnText}>Cancelar</Text>
            </Pressable>
          </View>
        </View>
      </Modal>

      {/* ── HORAS EXTRA — modal automático nearEnd (solo cliente) ─── */}
      <Modal visible={showClientNearEndModal} transparent animationType="slide">
        <View style={st.nearEndOverlay}>
          <View style={st.nearEndModal}>
            <Text style={st.nearEndTitle}>Quedan menos de 15 min</Text>
            <Text style={st.nearEndSub}>
              ¿Quieres que el grupo continúe? Selecciona cuánto tiempo extra deseas:
            </Text>

            {/* Recordatorio MSI */}
            <Text style={st.nearEndMsi}>
              💳 Paga a plazos hasta 9 meses con MSI.
            </Text>

            {clientPendingExtra ? (
              <View style={st.nearEndPending}>
                <Text style={st.nearEndPendingText}>
                  Solicitud de +{clientPendingExtra.hours}h enviada.{'\n'}Esperando confirmación del grupo…
                </Text>
              </View>
            ) : (
              <>
                {clientExtraOpts.map((opt, idx) => (
                  <Pressable
                    key={opt.hours}
                    style={[
                      st.nearEndRow,
                      idx < clientExtraOpts.length - 1 && st.nearEndRowBorder,
                    ]}
                    onPress={() => {
                      setShowClientNearEndModal(false);
                      setMsiPendingChoice({ hours: opt.hours, price: opt.price });
                      setMsiSelectedMonths(1);
                      setShowMsiModal(true);
                    }}
                  >
                    <View style={{ flex: 1 }}>
                      <Text style={st.nearEndHours}>+{opt.hours} {opt.hours === 1 ? 'hora' : 'horas'}</Text>
                    </View>
                    <Text style={st.nearEndPrice}>${opt.price.toLocaleString()}</Text>
                    <Text style={st.nearEndChevron}>›</Text>
                  </Pressable>
                ))}
              </>
            )}

            {/* Mensaje de seguridad — cliente */}
            <View style={st.securityNoticeClient}>
              <Text style={st.securityNoticeClientText}>
                🔒 Al contratar dentro de la app: el temporizador garantiza que el grupo toque, tienes pago seguro y respaldo legal, y soporte ante cualquier problema.
              </Text>
            </View>

            <Pressable style={st.nearEndDismiss} onPress={() => setShowClientNearEndModal(false)}>
              <Text style={st.nearEndDismissText}>Ahora no</Text>
            </Pressable>
          </View>
        </View>
      </Modal>

      {/* ── SELECTOR MSI HORA EXTRA — Stripe-style ──────────────── */}
      <Modal visible={showMsiModal} transparent animationType="slide">
        <View style={st.nearEndOverlay}>
          <View style={st.nearEndModal}>
            <Text style={st.nearEndTitle}>Selecciona tu plan</Text>
            {msiPendingChoice && (
              <Text style={[st.nearEndSub, { marginBottom: 8 }]}>
                +{msiPendingChoice.hours}h extra — ${msiPendingChoice.price.toLocaleString()}{resCurrency ? ` ${resCurrency}` : ''}
              </Text>
            )}

            {/* Logos de tarjetas */}
            <View style={st.cardLogosRow}>
              <VisaLogo />
              <McardLogo />
              <AmexLogo />
            </View>

            {/* Opciones MSI — MSI es exclusivo de MXN en toda la app (igual que
                create-payment-intent/create-extra-hour-payment-intent, que
                fuerzan 1 pago en USD). Hallazgo real 2026-09-10: antes se
                mostraban 3/6/9 meses también en reservas USD, pero el
                servidor las cobraba de un jalón sin avisar. */}
            {resCurrency === 'USD' && (
              <Text style={[st.msiCardFee, { marginBottom: 8 }]}>
                Meses con tarjeta disponibles solo para reservas en pesos (MXN).
              </Text>
            )}
            {(resCurrency === 'USD' ? [1] : EXTRA_MSI_OPTIONS).map(months => {
              const base = msiPendingChoice?.price ?? 0;
              const fee = EXTRA_MSI_FEE[months] ?? 0;
              const total = Math.round(base * (1 + fee));
              const monthly = Math.ceil(total / months);
              const isSelected = msiSelectedMonths === months;
              return (
                <Pressable
                  key={months}
                  style={[st.msiCard, isSelected && st.msiCardSelected]}
                  onPress={() => setMsiSelectedMonths(months)}
                >
                  <View style={{ flex: 1 }}>
                    <Text style={[st.msiCardTitle, isSelected && { color: '#16A34A' }]}>
                      {months === 1 ? '1 pago' : `${months} meses`}
                    </Text>
                    <Text style={st.msiCardFee}>
                      {months === 1 ? 'Sin cargo adicional' : `+${(fee * 100).toFixed(0)}% de cargo · $${monthly.toLocaleString()}${resCurrency ? ` ${resCurrency}` : ''}/mes`}
                    </Text>
                  </View>
                  <View style={{ alignItems: 'flex-end' }}>
                    <Text style={[st.msiCardPrice, isSelected && { color: '#16A34A' }]}>
                      ${total.toLocaleString()}{resCurrency ? ` ${resCurrency}` : ''}
                    </Text>
                    {months > 1 && (
                      <Text style={st.msiCardTotal}>total</Text>
                    )}
                    {isSelected && <Text style={{ fontSize: 16, color: '#16A34A', marginTop: 2 }}>✓</Text>}
                  </View>
                </Pressable>
              );
            })}

            {/* CTA */}
            <Pressable
              style={[st.msiSubmitBtn, stripeLoading && { opacity: 0.6 }]}
              disabled={stripeLoading}
              onPress={() => {
                if (!msiPendingChoice) return;
                setShowMsiModal(false);
                handleRequestWithStripe(msiPendingChoice.hours, msiPendingChoice.price, msiSelectedMonths);
              }}
            >
              {stripeLoading
                ? <ActivityIndicator color="#FFFFFF" />
                : <Text style={st.msiSubmitBtnText}>
                    Solicitar +{msiPendingChoice?.hours ?? 1}h al grupo
                  </Text>
              }
            </Pressable>

            <Pressable
              style={st.nearEndDismiss}
              onPress={() => { setShowMsiModal(false); setMsiPendingChoice(null); }}
            >
              <Text style={st.nearEndDismissText}>Cancelar</Text>
            </Pressable>
          </View>
        </View>
      </Modal>

      {/* ── CÓDIGO DE INICIO — validación al iniciar evento ──────── */}
      <Modal visible={showArrivalCodeModal} transparent animationType="fade">
        <Pressable style={st.codeModalOverlay} onPress={() => { Keyboard.dismiss(); setShowArrivalCodeModal(false); }}>
          <Pressable style={st.codeModal}>
            <Text style={st.codeModalTitle}>Iniciar evento</Text>
            <Text style={st.codeModalSub}>Pide al cliente sus 4 dígitos para comenzar</Text>

            <View style={st.codeDigitsRow}>
              {([codeRef0, codeRef1, codeRef2, codeRef3] as React.RefObject<any>[]).map((ref, i) => (
                <TextInput
                  key={i}
                  ref={ref}
                  style={[st.codeDigitInput, arrivalCodeInput[i] ? st.codeDigitInputFilled : undefined]}
                  value={arrivalCodeInput[i]}
                  onChangeText={text => handleCodeDigit(text, i)}
                  onKeyPress={({ nativeEvent }) => handleCodeKeyPress(nativeEvent.key, i)}
                  keyboardType="number-pad"
                  maxLength={1}
                  selectTextOnFocus
                  caretHidden
                />
              ))}
            </View>

            <Pressable
              style={[
                st.codeConfirmBtn,
                (arrivalCodeInput.join('').length < 4 || codeLoading) && { opacity: 0.45 },
              ]}
              onPress={handleCodeSubmit}
              disabled={arrivalCodeInput.join('').length < 4 || codeLoading}
            >
              {codeLoading
                ? <ActivityIndicator color="#FFFFFF" />
                : <Text style={st.codeConfirmBtnText}>Confirmar inicio</Text>
              }
            </Pressable>

            <Pressable
              style={st.codeCancelBtn}
              onPress={() => { Keyboard.dismiss(); setShowArrivalCodeModal(false); }}
            >
              <Text style={st.codeCancelBtnText}>Cancelar</Text>
            </Pressable>
          </Pressable>
        </Pressable>
      </Modal>

      {/* ── CÓDIGO DE SERVICIO TERMINADO (sql/639) ──────────────────
          Comida/Fotografía/renta de mesas-sillas-brincolines-inflables/
          Drones/cabinas — cierra el evento sin importar cuánto tiempo
          haya pasado, con un código NUEVO y distinto al de llegada. */}
      <Modal visible={showServiceCodeModal} transparent animationType="fade">
        <Pressable style={st.codeModalOverlay} onPress={() => { Keyboard.dismiss(); setShowServiceCodeModal(false); }}>
          <Pressable style={st.codeModal}>
            <Text style={st.codeModalTitle}>Marcar como terminado</Text>
            <Text style={st.codeModalSub}>Pide al cliente sus 4 dígitos de "servicio terminado"</Text>

            <View style={st.codeDigitsRow}>
              {([svcCodeRef0, svcCodeRef1, svcCodeRef2, svcCodeRef3] as React.RefObject<any>[]).map((ref, i) => (
                <TextInput
                  key={i}
                  ref={ref}
                  style={[st.codeDigitInput, serviceCodeInput[i] ? st.codeDigitInputFilled : undefined]}
                  value={serviceCodeInput[i]}
                  onChangeText={text => handleServiceCodeDigit(text, i)}
                  onKeyPress={({ nativeEvent }) => handleServiceCodeKeyPress(nativeEvent.key, i)}
                  keyboardType="number-pad"
                  maxLength={1}
                  selectTextOnFocus
                  caretHidden
                />
              ))}
            </View>

            <Pressable
              style={[
                st.codeConfirmBtn,
                (serviceCodeInput.join('').length < 4 || serviceCodeLoading) && { opacity: 0.45 },
              ]}
              onPress={handleServiceCodeSubmit}
              disabled={serviceCodeInput.join('').length < 4 || serviceCodeLoading}
            >
              {serviceCodeLoading
                ? <ActivityIndicator color="#FFFFFF" />
                : <Text style={st.codeConfirmBtnText}>Confirmar y terminar</Text>
              }
            </Pressable>

            <Pressable
              style={st.codeCancelBtn}
              onPress={() => { Keyboard.dismiss(); setShowServiceCodeModal(false); }}
            >
              <Text style={st.codeCancelBtnText}>Cancelar</Text>
            </Pressable>
          </Pressable>
        </Pressable>
      </Modal>
    </View>
  );
}

// ── Styles ───────────────────────────────────────────────────────────────

const st = StyleSheet.create({
  container: { flex: 1, backgroundColor: COLORS.bg },
  header: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingHorizontal: SPACING.xl, paddingVertical: 14,
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  scroll: { paddingHorizontal: 20, paddingVertical: 20, alignItems: 'center' },

  // ── Timer SVG Arc ──────────────────────────────────────────
  timerSection: { alignItems: 'center', marginBottom: 16, width: '100%' },
  // Container for SVG + absolute overlay
  timerSvgWrap: {
    width: 320, height: 320,
    alignItems: 'center', justifyContent: 'center',
    marginBottom: 16,
  },
  timerCenterOverlay: {
    position: 'absolute',
    top: 0, left: 0, right: 0, bottom: 0,
    alignItems: 'center', justifyContent: 'center',
    paddingHorizontal: 47,
  },
  progressBarTrack: {
    width: '100%', height: 7, borderRadius: 3.5,
    backgroundColor: COLORS.border, marginBottom: 8, overflow: 'hidden',
  },
  progressBarFill: { height: 7, borderRadius: 3.5 },

  // Segment badge
  segBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 10, paddingVertical: 4, borderRadius: 20,
    borderWidth: 1, marginBottom: 10,
  },
  segBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 10, letterSpacing: 1.2 },

  stateLabel: {
    fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted,
    letterSpacing: 1.5, marginBottom: 8,
  },

  // Time digits — inside circle
  timeRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'center' },
  digitCard: { alignItems: 'center' },
  timeDigit: { fontFamily: FONTS.title, fontSize: 34, lineHeight: 38, letterSpacing: -2 },
  timeUnit: {
    fontFamily: FONTS.body, fontSize: 7, color: COLORS.muted,
    letterSpacing: 1.2, marginTop: -2,
  },
  timeSep: {
    fontFamily: FONTS.title, fontSize: 13, lineHeight: 38,
    marginHorizontal: 2, marginBottom: 8, opacity: 0.35,
  },
  pauseLabel: {
    fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted,
    letterSpacing: 1.5, marginBottom: 6,
  },

  // ── State banners ───────────────────────────────────────────
  bannerWarmup: {
    width: '100%', alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(60,72,100,0.18)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(100,120,160,0.25)',
    paddingVertical: 14, paddingHorizontal: 20, marginBottom: 16,
  },
  bannerWarmupText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.muted2, letterSpacing: 0.3,
  },
  bannerLive: {
    width: '100%', flexDirection: 'row' as const, alignItems: 'center' as const,
    justifyContent: 'center' as const, gap: 8,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingVertical: 6, paddingHorizontal: 14, marginBottom: 14,
  },
  bannerLiveText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green, letterSpacing: 0.8,
  },
  bannerDot: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.green },
  bannerBreak: {
    width: '100%', alignItems: 'center' as const, justifyContent: 'center' as const,
    backgroundColor: 'rgba(66,133,244,0.10)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(66,133,244,0.30)',
    paddingVertical: 6, paddingHorizontal: 14, marginBottom: 14, gap: 3,
  },
  bannerBreakText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.blue, letterSpacing: 0.8,
  },
  bannerBreakSub: {
    fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.blue, opacity: 0.75,
  },

  elapsedLabel: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 8, letterSpacing: 0.3,
  },

  // Progress text only (bar replaced by SVG arc)
  progressText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  // ── Break info card ─────────────────────────────────────────
  breakCard: {
    width: '100%', backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 14, marginBottom: 14, gap: 8,
  },
  breakRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  breakLabel: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  breakValue: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  breakInfoText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, lineHeight: 18 },
  changeBreak: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green, marginTop: 4 },

  // Schedule timeline
  scheduleSection: { marginTop: 16, borderTopWidth: 1, borderTopColor: COLORS.border, paddingTop: 14 },
  scheduleTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 12,
  },
  scheduleRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingVertical: 10, paddingHorizontal: 10, borderRadius: RADIUS.md, marginBottom: 4,
  },
  scheduleRowActive:      { backgroundColor: 'rgba(0,230,118,0.08)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)' },
  scheduleRowActiveBreak: { backgroundColor: 'rgba(96,165,250,0.08)', borderWidth: 1, borderColor: 'rgba(96,165,250,0.3)' },
  scheduleRowPast: { opacity: 0.5 },
  scheduleIcon: {
    width: 30, height: 30, borderRadius: 15, alignItems: 'center', justifyContent: 'center',
  },
  scheduleIconMusic: { backgroundColor: 'rgba(0,230,118,0.12)' },
  scheduleIconBreak: { backgroundColor: 'rgba(96,165,250,0.12)' },
  scheduleIconMusicActive: { backgroundColor: COLORS.green },
  scheduleIconBreakActive: { backgroundColor: '#60A5FA' },
  scheduleLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  scheduleLabelPast: { color: COLORS.muted },
  scheduleTime: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1 },
  scheduleTimePast: { color: COLORS.muted },
  scheduleDuration: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  // Extra-hours golden treatment
  scheduleRowExtra:       { backgroundColor: 'rgba(251,191,36,0.08)', borderWidth: 1, borderColor: 'rgba(251,191,36,0.25)' },
  scheduleRowExtraActive: { backgroundColor: 'rgba(251,191,36,0.16)', borderWidth: 1, borderColor: 'rgba(251,191,36,0.5)' },
  scheduleRowExtraPast:   { backgroundColor: 'rgba(251,191,36,0.05)', borderWidth: 1, borderColor: 'rgba(251,191,36,0.12)', opacity: 0.75 },
  scheduleIconExtra:      { backgroundColor: 'rgba(251,191,36,0.15)' },
  scheduleIconExtraActive:{ backgroundColor: '#FBBF24' },
  scheduleLabelExtra:     { color: '#FBBF24' },
  scheduleTimeExtra:      { color: 'rgba(251,191,36,0.7)' },
  scheduleDurationExtra:  { color: '#FBBF24' },
  scheduleBadgeExtra: {
    backgroundColor: 'rgba(251,191,36,0.2)', borderRadius: 4, paddingHorizontal: 5, paddingVertical: 1,
  },
  scheduleBadgeExtraText: { fontFamily: FONTS.bodySemiBold, fontSize: 10, color: '#FBBF24' },

  selectBreakBtn: {
    width: '100%', flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: '#FFFFFF', borderRadius: RADIUS.full,
    padding: 14, marginBottom: 14,
    shadowColor: '#00E676', shadowOpacity: 0.25, shadowRadius: 8, shadowOffset: { width: 0, height: 2 },
    elevation: 4,
  },
  selectBreakText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#000' },

  // ── Status, info, warning ──────────────────────────────────
  statusRow: { marginBottom: 14 },
  infoCard: {
    width: '100%', backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 14, gap: 10,
  },
  infoRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  infoText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, flex: 1 },
  mapBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: '#FFFFFF', borderRadius: RADIUS.full,
    paddingVertical: 10, paddingHorizontal: 14, marginTop: 6,
    shadowColor: '#00E676', shadowOpacity: 0.25, shadowRadius: 8, shadowOffset: { width: 0, height: 2 },
    elevation: 4,
  },
  mapBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#000', flex: 1 },
  warningBanner: {
    width: '100%', backgroundColor: 'rgba(255,152,0,0.12)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.orange,
    padding: SPACING.lg, marginBottom: 14,
  },
  warningText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.orange, marginBottom: 10 },
  extraPriceBox: {
    backgroundColor: 'rgba(0,0,0,0.25)', borderRadius: RADIUS.md,
    padding: 10, marginBottom: 10, gap: 4,
  },
  extraPriceTitle: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginBottom: 2 },
  extraPriceValue:  { fontFamily: FONTS.title, fontSize: 18, color: COLORS.orange },
  extraPriceLine:   { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  warningBtn: {
    backgroundColor: COLORS.orange, paddingVertical: 10,
    paddingHorizontal: 16, borderRadius: RADIUS.sm, alignSelf: 'flex-start', marginTop: 4,
  },
  warningBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.black },
  actions: { width: '100%', marginTop: 8 },
  chatBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    width: '100%', backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 14, marginTop: 12,
  },
  chatBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg, flex: 1, textAlign: 'center' },
  chatBadge: {
    minWidth: 20, height: 20, borderRadius: 10,
    backgroundColor: '#EF5350', borderWidth: 2, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center', paddingHorizontal: 4,
    position: 'absolute', right: 14,
  },
  chatBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: '#fff' },
  chatFab: {
    position: 'absolute', bottom: 24, right: 20,
    width: 56, height: 56, borderRadius: 28,
    backgroundColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
    shadowColor: COLORS.green, shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.4, shadowRadius: 8, elevation: 8,
  },
  chatFabBadge: {
    position: 'absolute', top: 6, right: 6,
    minWidth: 18, height: 18, borderRadius: 9,
    backgroundColor: '#EF5350', borderWidth: 2, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center', paddingHorizontal: 3,
  },
  readOnlyBanner: {
    width: '100%', flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: 'rgba(156,39,176,0.07)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(156,39,176,0.3)',
    padding: 14, marginTop: 8,
  },
  readOnlyText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.purple, marginBottom: 2 },
  readOnlyHint: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },
  earningCard: {
    width: '100%', backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.green,
    padding: SPACING.lg, marginTop: 12, alignItems: 'center', gap: 4,
  },
  earningLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, letterSpacing: 0.3 },
  earningAmount: { fontFamily: FONTS.title, fontSize: 32, color: COLORS.green },
  earningHint: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, textAlign: 'center', marginTop: 2 },

  // ── Details toggle button ────────────────────────────────────
  detailsToggleBtn: {
    width: '100%', paddingVertical: 12, paddingHorizontal: 16,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', marginBottom: 12,
  },
  detailsToggleBtnText: {
    fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green,
  },

  // ── Pre-event info card ──────────────────────────────────────
  preEventSection: {
    alignItems: 'center', width: '100%',
    paddingVertical: 36, paddingHorizontal: 24,
    gap: 10, marginBottom: 8,
  },
  preEventHeadline: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted,
    textTransform: 'uppercase', letterSpacing: 1.5, marginBottom: 4,
  },
  preEventDateText: {
    fontFamily: FONTS.title, fontSize: 20, color: COLORS.text,
    textAlign: 'center', lineHeight: 28,
  },
  preEventTimeText: {
    fontFamily: FONTS.title, fontSize: 44, color: COLORS.green, letterSpacing: 1,
  },
  preEventCountdownBox: {
    flexDirection: 'row', alignItems: 'center', gap: 7,
    marginTop: 4, paddingHorizontal: 18, paddingVertical: 10,
    borderRadius: RADIUS.full,
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
  },
  preEventCountdownTxt: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  preEventStatusBadge: {
    marginTop: 4, paddingHorizontal: 14, paddingVertical: 6,
    borderRadius: RADIUS.full, backgroundColor: COLORS.card,
    borderWidth: 1, borderColor: COLORS.border,
  },
  preEventStatusText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  // ── Extra sections (invited talents + distribution) ────────
  extraSection: {
    width: '100%', backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginTop: 14, gap: 10,
  },
  extraSectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text,
    textTransform: 'uppercase', letterSpacing: 0.7, marginBottom: 2,
  },

  // Talent rows
  talentRow:       { flexDirection: 'row', alignItems: 'center', gap: 10 },
  talentAvatar: {
    width: 34, height: 34, borderRadius: 17,
    backgroundColor: COLORS.greenMuted, borderWidth: 1, borderColor: COLORS.green,
    alignItems: 'center', justifyContent: 'center',
  },
  talentAvatarText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },
  talentName:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, flex: 1 },
  talentChip: {
    paddingHorizontal: 8, paddingVertical: 3, borderRadius: RADIUS.full, borderWidth: 1,
  },
  talentChipText: { fontFamily: FONTS.bodyMedium, fontSize: 11 },

  // Distribution
  distNote:     { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginBottom: 2 },
  distSubLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 1 },
  distRow: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  distLabel:        { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, flex: 1 },
  distAmount:       { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  distTotalRow:     { borderBottomWidth: 0, paddingTop: 10, marginTop: 2 },
  distTotalLabel:   { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, flex: 1 },
  distTotalAmount:  { fontFamily: FONTS.title, fontSize: 16, color: COLORS.green },
  pendingBadge: {
    paddingHorizontal: 8, paddingVertical: 2, borderRadius: RADIUS.full,
    backgroundColor: 'rgba(255,179,0,0.1)', borderWidth: 1, borderColor: 'rgba(255,179,0,0.35)',
  },
  pendingText: { fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.gold },

  // Pay button
  payBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingVertical: 14, alignItems: 'center', marginTop: 8,
  },
  payBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },
  payBtnNote: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted,
    textAlign: 'center', marginTop: 4, marginBottom: 8,
  },

  // ── Stripe Connect payout status ────────────────────────────
  stripePayoutBox: {
    marginTop: 12,
    backgroundColor: COLORS.bg,
    borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14, gap: 4,
  },
  stripePayoutRow:      { flexDirection: 'row', alignItems: 'flex-start', gap: 10, paddingVertical: 4 },
  stripePayoutDivider:  { height: 1, backgroundColor: COLORS.border, marginVertical: 2 },
  stripePayoutLabel:    { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
  stripePayoutLabelDone: { color: COLORS.green },
  stripePayoutId:       { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, marginTop: 1 },

  // ── End-of-event modal ─────────────────────────────────────
  endModalOverlay: {
    flex: 1, backgroundColor: 'rgba(0,0,0,0.7)',
    justifyContent: 'center', alignItems: 'center', padding: 30,
  },
  endModal: {
    width: '100%', backgroundColor: COLORS.card,
    borderRadius: 24, padding: 28, alignItems: 'center',
    borderWidth: 1, borderColor: COLORS.border,
  },
  endModalTitle: {
    fontFamily: FONTS.title, fontSize: 24, color: COLORS.text,
    textAlign: 'center', marginBottom: 8,
  },
  endModalSub: {
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 22, marginBottom: 24,
  },
  endModalBtnExtra: {
    width: '100%', backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 16, paddingHorizontal: 20, alignItems: 'center', marginBottom: 12,
  },
  endModalBtnExtraText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.bg,
  },
  endModalBtnExtraDesc: {
    fontFamily: FONTS.body, fontSize: 12, color: 'rgba(0,0,0,0.5)', marginTop: 2,
  },
  endModalBtnFinish: {
    width: '100%', backgroundColor: COLORS.card2, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 16, paddingHorizontal: 20, alignItems: 'center',
  },
  endModalBtnFinishText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.muted2,
  },
  endModalBtnFinishDesc: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 2,
  },

  // ── Break type modal ───────────────────────────────────────
  modalOverlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)', justifyContent: 'flex-end' },
  modal: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    padding: SPACING.xl, paddingBottom: 40, maxHeight: '85%',
  },
  modalTitle: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, marginBottom: 6 },
  modalSub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20, marginBottom: 20 },
  breakOpt: {
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14, marginBottom: 10,
  },
  breakOptActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  breakOptLeft: { flexDirection: 'row', alignItems: 'flex-start', gap: 12 },
  breakOptRadio: {
    width: 20, height: 20, borderRadius: 10,
    borderWidth: 2, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center', marginTop: 2,
  },
  breakOptRadioActive: { borderColor: COLORS.green },
  breakOptRadioDot: { width: 10, height: 10, borderRadius: 5, backgroundColor: COLORS.green },
  breakOptLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 4 },
  breakOptOnlyGroup: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  breakOptDesc: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18 },
  breakOptCalc: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, marginTop: 4 },
  confirmBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 15, alignItems: 'center', marginTop: 10,
  },
  confirmBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },
  cancelBreakBtn: {
    paddingVertical: 14, alignItems: 'center', marginTop: 6,
  },
  cancelBreakBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },

  // ── Client extra hours ─────────────────────────────────────
  extraHoursCard: {
    width: '100%', backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 16, marginBottom: 14, gap: 10,
  },
  extraHoursTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  extraHoursSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: -4 },
  extraHourOpt: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    backgroundColor: COLORS.bg, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12,
  },
  extraHourOptActive: { borderColor: COLORS.green, backgroundColor: COLORS.greenMuted },
  extraHourOptLabel: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },
  extraHourOptPrice: { fontFamily: FONTS.title, fontSize: 18, color: COLORS.muted2 },
  extraHourPayBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 14, alignItems: 'center', marginTop: 4,
  },
  extraHourPayBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },

  // ── Event details section (group + talent) ─────────────────
  detailsSection: { width: '100%', gap: 12, marginBottom: 14 },

  clientReqCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 16, gap: 10,
  },
  clientReqTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2,
    textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 4,
  },
  clientReqRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingVertical: 6, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  clientReqLabel: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, flex: 1 },
  clientReqValue: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, textAlign: 'right', flex: 1 },

  // ── Review card (estado terminal completado) ──────────────────
  reviewCard: {
    backgroundColor: 'rgba(0,230,118,0.04)',
    borderLeftWidth: 3,
    borderLeftColor: COLORS.green,
    paddingVertical: 10,
    paddingHorizontal: 12,
    marginLeft: 20,
    marginRight: 0,
    marginTop: 8,
  },
  reviewStarsRow: { flexDirection: 'row', alignItems: 'center', gap: 3, marginBottom: 6 },
  reviewStarOn:   { color: '#FBBF24', fontSize: 16 },
  reviewStarOff:  { color: 'rgba(255,255,255,0.2)', fontSize: 16 },
  reviewCommentInline: {
    fontFamily: FONTS.body,
    fontSize: 13,
    fontStyle: 'italic',
    color: COLORS.muted2,
    marginBottom: 4,
    lineHeight: 18,
  },
  reviewCardFooter: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted },

  // Commission breakdown
  commissionBox: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: 16, gap: 0,
  },
  commRow: {
    flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
    paddingVertical: 10, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  commLabel: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  commSub: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 1 },
  commValue: { fontFamily: FONTS.bodySemiBold, fontSize: 13 },
  commNetRow: { borderBottomWidth: 0, paddingTop: 12, marginTop: 2 },
  commNetLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  commNetValue: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.green },

  commMemberTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted,
    textTransform: 'uppercase', letterSpacing: 0.7, marginTop: 16, marginBottom: 4,
  },
  memberDistRow: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingVertical: 8, borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  memberDistName: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  memberDistRole: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 1 },
  memberDistAmount: { fontFamily: FONTS.title, fontSize: 18 },
  memberDistStatus: { fontFamily: FONTS.body, fontSize: 10, marginTop: 1 },

  // ── Client extra hours purchase ───────────────────────────
  clientExtraCard: {
    width: '100%', backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.green + '40',
    padding: 16, marginBottom: 14,
  },
  clientExtraTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 4 },
  clientExtraSub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 14, lineHeight: 19 },
  clientExtraOpts: { flexDirection: 'row', gap: 10 },
  clientExtraOpt: {
    flex: 1, alignItems: 'center', paddingVertical: 14,
    backgroundColor: COLORS.bg, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.green,
  },
  clientExtraOptDone: { borderColor: COLORS.muted, backgroundColor: COLORS.card2, opacity: 0.6 },
  clientExtraOptHours: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.green, marginBottom: 2 },
  clientExtraOptPrice: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: '#16A34A' },
  clientExtraOptDoneLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green, marginTop: 4 },
  clientExtraOptDisabled: { opacity: 0.4 },
  clientExtraOptNoFunds: { fontFamily: FONTS.body, fontSize: 10, color: '#CC4444', marginTop: 2 },

  // ── Grupo: lo que recibe (sin comisión visible) ────────────────
  groupEarningsBox: {
    alignItems: 'center', paddingVertical: 20,
    backgroundColor: 'rgba(0,230,118,0.06)',
    borderRadius: RADIUS.md, marginBottom: 16,
  },
  groupEarningsLabel: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 6,
  },
  groupEarningsAmount: {
    fontFamily: FONTS.title, fontSize: 32, color: COLORS.green,
  },

  // ── Avisos de seguridad ───────────────────────────────────────
  securityNoticeGroup: {
    backgroundColor: 'rgba(255,255,255,0.04)', borderRadius: RADIUS.md,
    padding: 12, marginBottom: 12,
  },
  securityNoticeGroupText: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18,
  },
  securityNoticeClient: {
    marginTop: 16, paddingTop: 16,
    borderTopWidth: 1, borderTopColor: 'rgba(0,0,0,0.08)',
  },
  securityNoticeClientText: {
    fontFamily: FONTS.body, fontSize: 12, color: '#777777',
    lineHeight: 18, textAlign: 'center',
  },

  // ── Banner pendiente extra (cliente espera confirmación) ──────
  bannerPendingExtra: {
    width: '100%', alignItems: 'center' as const, justifyContent: 'center' as const,
    backgroundColor: 'rgba(255,152,0,0.12)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(255,152,0,0.30)',
    paddingHorizontal: 14, paddingVertical: 6, marginBottom: 14, gap: 2,
  },
  bannerPendingExtraText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.orange, letterSpacing: 0.8,
  },
  bannerPendingExtraSub: {
    fontFamily: FONTS.bodyMedium, fontSize: 10, color: COLORS.orange, opacity: 0.8,
  },

  // ── Near-end modal — cliente (estilo bottom sheet premium) ────
  nearEndOverlay: {
    flex: 1, backgroundColor: 'rgba(0,0,0,0.72)', justifyContent: 'flex-end',
  },
  nearEndModal: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    paddingHorizontal: 24, paddingTop: 28, paddingBottom: 36,
  },
  nearEndTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 17, color: COLORS.text, marginBottom: 8,
  },
  nearEndSub: {
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, lineHeight: 21, marginBottom: 20,
  },
  nearEndRow: {
    flexDirection: 'row', alignItems: 'center', paddingVertical: 16,
  },
  nearEndRowBorder: {
    borderBottomWidth: 1, borderBottomColor: COLORS.border,
  },
  nearEndHours: {
    fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text,
  },
  nearEndPrice: {
    fontFamily: FONTS.title, fontSize: 18, color: '#16A34A', marginRight: 10,
  },
  nearEndChevron: {
    fontSize: 22, color: COLORS.muted, fontFamily: FONTS.body,
  },
  nearEndPending: {
    paddingVertical: 24, alignItems: 'center',
  },
  nearEndPendingText: {
    fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 22,
  },
  nearEndMsi: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted,
    textAlign: 'center', marginBottom: 16, lineHeight: 17,
  },
  nearEndInfoBox: {
    marginTop: 14, alignItems: 'center', paddingVertical: 10,
  },
  nearEndInfoText: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, textAlign: 'center',
  },
  nearEndDismiss: {
    marginTop: 20, alignItems: 'center', paddingVertical: 12,
  },
  nearEndDismissText: {
    fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.muted,
  },

  // ── Extra hours (client view) ─────────────────────────────
  extraOfferCard: {
    width: '100%', backgroundColor: COLORS.greenMuted,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.green + '50',
    padding: 16, marginBottom: 14,
  },
  extraOfferTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green, marginBottom: 6 },
  extraOfferSub: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, lineHeight: 20, marginBottom: 12 },
  extraOfferBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.md,
    paddingVertical: 11, alignItems: 'center',
  },
  extraOfferBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },

  extraHintCard: {
    width: '100%', backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    padding: 16, marginBottom: 14,
  },
  extraHintTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 4 },
  extraHintSub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 19, marginBottom: 10 },
  extraHintPrices: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  extraHintPill: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 5,
  },
  extraHintPillText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.green },


  // ── Punctuality banner ─────────────────────────────────────
  punctualityBanner: {
    width: '100%', flexDirection: 'row', alignItems: 'flex-start', gap: 12,
    backgroundColor: 'rgba(255,179,0,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.35)',
    padding: 14, marginBottom: 14,
  },
  punctualityIcon: { fontSize: 20, marginTop: 1 },
  punctualityTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.gold, marginBottom: 3 },
  punctualitySub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 19 },

  // 🍽️📸🪑 sql/639 — aclaración bajo el círculo para categorías de código
  serviceCodeHint: {
    fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 18, marginTop: 10,
    paddingHorizontal: SPACING.lg,
  },

  // ── Arrived banner ─────────────────────────────────────────
  arrivedBanner: {
    width: '100%', flexDirection: 'row', alignItems: 'flex-start', gap: 12,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.green + '40',
    padding: 14, marginBottom: 14,
  },
  arrivedIcon: { fontSize: 20, marginTop: 1 },
  arrivedTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green, marginBottom: 3 },
  arrivedSub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 19 },

  // Anti-bypass warning (client view)
  antiBypassBanner: {
    backgroundColor: 'rgba(255,152,0,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(255,152,0,0.3)',
    padding: 12, marginBottom: 8,
  },
  antiBypassText: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.orange, lineHeight: 18, textAlign: 'center',
  },

  // Client pending extra hours
  clientExtraPending: {
    alignItems: 'center', padding: 20, gap: 8,
    backgroundColor: 'rgba(255,255,255,0.04)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
  },
  clientExtraPendingIcon: { fontSize: 32 },
  clientExtraPendingText: {
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 20,
  },

  // Group extra hours commission breakdown box (inside confirm modal)
  extraCommBox: {
    width: '100%', backgroundColor: 'rgba(0,230,118,0.06)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.2)',
    padding: 14, marginBottom: 16, gap: 6,
  },
  extraCommTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, marginBottom: 6,
  },
  extraCommRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  extraCommLabel: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2 },
  extraCommValue: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },

  // ── Header improvements ────────────────────────────────────
  headerSub: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 1, letterSpacing: 0.2 },
  rolePill: {
    paddingHorizontal: 10, paddingVertical: 6, borderRadius: RADIUS.full,
    borderWidth: 1, alignItems: 'center', justifyContent: 'center',
  },
  rolePillText: { fontSize: 16 },

  // ── Role context strip ────────────────────────────────────
  roleContextStrip: {
    width: '100%', flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 16, paddingVertical: 12,
    marginBottom: 14,
  },
  roleContextLeft: { flex: 1, gap: 2 },
  roleContextLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  roleContextSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },
  clientAvatarBox: {
    width: 32, height: 32, borderRadius: 16, overflow: 'hidden',
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  clientAvatarImg:     { width: 32, height: 32, borderRadius: 16 },
  clientAvatarInitial: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2 },
  roleContextRight: { alignItems: 'flex-end' },
  roleContextHours: { fontFamily: FONTS.title, fontSize: 20, color: COLORS.green, lineHeight: 22 },
  roleContextHoursLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, letterSpacing: 0.3 },

  // ── Improved arrived / readOnly banners ────────────────────
  arrivedIconWrap: {
    width: 44, height: 44, borderRadius: 22,
    backgroundColor: 'rgba(0,230,118,0.12)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    alignItems: 'center', justifyContent: 'center',
  },
  readOnlyIconWrap: {
    width: 44, height: 44, borderRadius: 22,
    backgroundColor: 'rgba(156,39,176,0.10)', borderWidth: 1, borderColor: 'rgba(156,39,176,0.3)',
    alignItems: 'center', justifyContent: 'center',
  },
  exactMapWrap:  { marginTop: 12 },
  exactMapLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginBottom: 6 },
  folioChip: {
    fontFamily: FONTS.title, fontSize: 14, color: COLORS.green,
    letterSpacing: 2.5, textAlign: 'center',
    alignSelf: 'center', overflow: 'hidden',
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    borderRadius: RADIUS.full, paddingHorizontal: 16, paddingVertical: 6,
    marginBottom: 4,
  },
  supportRow:     { alignSelf: 'center', marginTop: 14, paddingVertical: 8, paddingHorizontal: 14 },
  supportRowText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, textDecorationLine: 'underline' },
  guideLink:   { alignSelf: 'center', marginBottom: 8, paddingVertical: 2, paddingHorizontal: 10 },
  guideLinkTx: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2, textDecorationLine: 'underline' },
  exactMap:      { width: '100%', height: 220, borderRadius: RADIUS.lg, overflow: 'hidden' },

  // ── Actions (Commit 4) ────────────────────────────────────
  autoStartHint: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2,
    textAlign: 'center', marginBottom: 8,
  },
  endEventLink: {
    alignSelf: 'center', paddingVertical: 10, paddingHorizontal: 16, marginTop: 4,
  },
  endEventLinkText: {
    fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted,
  },

  // ── End-event confirmation modal ─────────────────────────
  endConfirmOverlay: {
    flex: 1, backgroundColor: 'rgba(0,0,0,0.72)',
    alignItems: 'center', justifyContent: 'center', padding: 24,
  },
  endConfirmCard: {
    width: '100%', backgroundColor: COLORS.card,
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: COLORS.border,
    padding: 24,
  },
  endConfirmTitle: {
    fontFamily: FONTS.title, fontSize: 20, color: COLORS.text,
    marginBottom: 10,
  },
  endConfirmBody: {
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2,
    lineHeight: 20, marginBottom: 24,
  },
  endConfirmRow: {
    flexDirection: 'row', gap: 12,
  },
  endConfirmBtn: {
    flex: 1, paddingVertical: 14,
    borderRadius: RADIUS.lg, alignItems: 'center', justifyContent: 'center',
  },
  endConfirmCancel: {
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  endConfirmCancelText: {
    fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2,
  },
  endConfirmOk: {
    backgroundColor: '#B71C1C',
  },
  endConfirmOkText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#fff',
  },

  // ── Arrival code modal (estilo Uber) ─────────────────────
  codeModalOverlay: {
    flex: 1, backgroundColor: 'rgba(0,0,0,0.55)',
    alignItems: 'center', justifyContent: 'center', padding: 24,
  },
  codeModal: {
    width: '100%', backgroundColor: '#FFFFFF',
    borderRadius: 20, padding: 28, alignItems: 'center',
    shadowColor: '#000', shadowOffset: { width: 0, height: 8 },
    shadowOpacity: 0.12, shadowRadius: 24, elevation: 12,
  },
  codeModalTitle: {
    fontFamily: FONTS.title, fontSize: 20, color: '#111827',
    textAlign: 'center', marginBottom: 6,
  },
  codeModalSub: {
    fontFamily: FONTS.body, fontSize: 13, color: '#6B7280',
    textAlign: 'center', lineHeight: 20, marginBottom: 28,
  },
  codeDigitsRow: {
    flexDirection: 'row', gap: 12, marginBottom: 32,
  },
  codeDigitInput: {
    width: 62, height: 72, borderRadius: 12,
    backgroundColor: '#FFFFFF', borderWidth: 1.5, borderColor: '#D1D5DB',
    color: '#111827', fontFamily: FONTS.title, fontSize: 32,
    textAlign: 'center',
  },
  codeDigitInputFilled: {
    borderColor: '#111827', backgroundColor: '#F9FAFB',
  },
  codeConfirmBtn: {
    width: '100%', backgroundColor: '#111827', borderRadius: 14,
    paddingVertical: 16, alignItems: 'center', marginBottom: 10,
  },
  codeConfirmBtnText: {
    fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#FFFFFF',
  },
  codeCancelBtn: {
    width: '100%', backgroundColor: '#F3F4F6', borderRadius: 14,
    paddingVertical: 14, alignItems: 'center',
  },
  codeCancelBtnText: {
    fontFamily: FONTS.bodyMedium, fontSize: 14, color: '#374151',
  },

  // ── Banner "Paga ahora" (cliente) ────────────────────────
  payNowBanner: {
    width: '100%', backgroundColor: 'rgba(22,163,74,0.07)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(22,163,74,0.25)',
    padding: 18, marginBottom: 14, alignItems: 'center',
  },
  payNowBannerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: '#16A34A', marginBottom: 4 },
  payNowBannerSub: { fontFamily: FONTS.body, fontSize: 13, color: '#555555', marginBottom: 14 },
  payNowBannerBtn: {
    backgroundColor: '#16A34A', borderRadius: RADIUS.lg,
    paddingVertical: 14, paddingHorizontal: 36, marginBottom: 8,
  },
  payNowBannerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#FFFFFF' },
  payNowBannerTimer: { fontFamily: FONTS.body, fontSize: 11, color: '#888888' },

  // ── Logos de tarjetas ─────────────────────────────────────
  cardLogosRow: { flexDirection: 'row', gap: 8, marginBottom: 18 },

  // ── MSI card options (Stripe-style) ──────────────────────
  msiCard: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: COLORS.card2, borderRadius: 12,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14, marginBottom: 8,
  },
  msiCardSelected: { borderColor: '#16A34A', backgroundColor: 'rgba(22,163,74,0.10)' },
  msiCardTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text, marginBottom: 2 },
  msiCardFee: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted },
  msiCardPrice: { fontFamily: FONTS.title, fontSize: 17, color: COLORS.text },
  msiCardTotal: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, marginTop: 1 },

  // ── Botón CTA MSI ─────────────────────────────────────────
  msiSubmitBtn: {
    width: '100%', backgroundColor: '#16A34A', borderRadius: RADIUS.lg,
    paddingVertical: 16, alignItems: 'center', marginTop: 10, marginBottom: 2,
  },
  msiSubmitBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: '#FFFFFF' },

  // ── Badge método de pago (modal grupo) ───────────────────
  paymentMethodBadge: {
    backgroundColor: 'rgba(66,133,244,0.08)', borderRadius: RADIUS.md,
    paddingHorizontal: 14, paddingVertical: 8, marginBottom: 14, alignSelf: 'center',
  },
  paymentMethodBadgeText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: '#4285F4' },

  // ── Icon buttons — píldoras blancas elegantes (Llegué / Iniciar evento) ──
  iconBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    gap: 8, borderRadius: RADIUS.full, paddingVertical: 17, paddingHorizontal: 24, width: '100%',
    shadowColor: '#00E676', shadowOpacity: 0.3, shadowRadius: 10, shadowOffset: { width: 0, height: 3 },
    elevation: 5,
  },
  iconBtnPrimary: { backgroundColor: '#FFFFFF' },
  iconBtnOutline: { backgroundColor: '#FFFFFF' },
  iconBtnDisabled: { opacity: 0.45 },
  iconBtnLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 16, letterSpacing: 0.3 },
  // Pill chico blanco para "Ofrecer horas extra" (separado del timer)
  extraSmallBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center',
    alignSelf: 'center', gap: 6, marginTop: 26,
    backgroundColor: '#FFFFFF', borderRadius: RADIUS.full,
    paddingVertical: 9, paddingHorizontal: 18,
    shadowColor: '#00E676', shadowOpacity: 0.3, shadowRadius: 8, shadowOffset: { width: 0, height: 2 },
    elevation: 4,
  },
  extraSmallBtnTx: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#000', letterSpacing: 0.2 },
});
