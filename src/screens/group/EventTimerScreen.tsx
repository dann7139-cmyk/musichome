import { ArrowLeft, CheckCircle, Clock, Coffee, ExternalLink, MapPin, MessageCircle, Music2, Navigation } from 'lucide-react-native';
import React, { useEffect, useMemo, useRef, useState } from 'react';
import MapView, { Marker } from 'react-native-maps';
import Svg, { Circle } from 'react-native-svg';
import {
  Alert,
  Animated,
  Easing,
  Image,
  Linking,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from '../../components/ui/Button';
import Badge from '../../components/ui/Badge';
import Particles from '../../components/ui/Particles';
import RatingModal, { type RatingSubject } from '../../components/ui/RatingModal';
import { generateBreakSchedule, isPaid } from '../../utils/calculations';

const RING_R    = 145;
const RING_SW   = 14;
const RING_CIRC = 2 * Math.PI * RING_R; // ≈ 910.9

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
    type: 'C',
    label: '20 min de descanso',
    desc: (hours: number) =>
      `Un solo descanso de 20 min a la mitad del evento\n${hours}h contratadas = ${formatMinutes(hours * 60 - 20)} de música + 20 min descanso`,
    clientVisible: true,
    breakMinutesFor: (_hours: number) => 20,
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
        <Text style={pp.title}>Pago no procesado</Text>
        <Text style={pp.body}>{reason}</Text>

        <View style={pp.infoBox}>
          <Text style={pp.infoTitle}>¿Qué pasa ahora?</Text>
          <Text style={pp.infoLine}>• El evento quedó registrado como completado</Text>
          <Text style={pp.infoLine}>• Tu pago aparece como "Pendiente de cobro" en la reserva</Text>
          <Text style={pp.infoLine}>• El cliente recibió una notificación para resolver el pago</Text>
          <Text style={pp.infoLine}>• Puedes contactar a soporte desde tu perfil si no se resuelve</Text>
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
    flex: 1, backgroundColor: COLORS.bg,
    alignItems: 'center', justifyContent: 'center', padding: 28,
  },
  card: { width: '100%', alignItems: 'center' },
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
    width: '100%', backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 16, alignItems: 'center',
  },
  btnText: { fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.muted2 },
});

// ── Celebration overlay ───────────────────────────────────────────────────────

const EMOJIS = ['🎉','🎊','🎵','🎶','✨','🎸','🔥','💫','⭐','🎤'];

function CelebrationOverlay({ isOwner, userRole, payouts, currentUserId, onOfferExtra, onClose }: {
  isOwner: boolean;
  userRole?: string;
  payouts: EventPayout[];
  currentUserId: string | null;
  onOfferExtra: () => void;
  onClose: () => void;
}) {
  const myPayout = payouts.find(p => p.user_id === currentUserId);
  const particles = useRef(Array.from({ length: 24 }, () => ({
    x: new Animated.Value(0),
    y: new Animated.Value(0),
    opacity: new Animated.Value(0),
    scale: new Animated.Value(0),
  }))).current;

  const titleScale = useRef(new Animated.Value(0.4)).current;
  const titleOpacity = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    // Title entrance
    Animated.parallel([
      Animated.spring(titleScale, { toValue: 1, friction: 5, useNativeDriver: true }),
      Animated.timing(titleOpacity, { toValue: 1, duration: 400, useNativeDriver: true }),
    ]).start();

    // Burst particles
    particles.forEach((p, i) => {
      const angle = (i / particles.length) * 2 * Math.PI;
      const dist = 120 + Math.random() * 80;
      Animated.sequence([
        Animated.delay(i * 30),
        Animated.parallel([
          Animated.timing(p.opacity, { toValue: 1, duration: 150, useNativeDriver: true }),
          Animated.spring(p.scale,   { toValue: 1 + Math.random() * 0.8, friction: 4, useNativeDriver: true }),
          Animated.timing(p.x,       { toValue: Math.cos(angle) * dist, duration: 600, useNativeDriver: true }),
          Animated.timing(p.y,       { toValue: Math.sin(angle) * dist, duration: 600, useNativeDriver: true }),
        ]),
        Animated.timing(p.opacity, { toValue: 0, duration: 400, useNativeDriver: true }),
      ]).start();
    });
  }, []);

  return (
    <View style={cel.overlay}>
      {/* Burst particles */}
      <View style={cel.burstCenter} pointerEvents="none">
        {particles.map((p, i) => (
          <Animated.Text
            key={i}
            style={[
              cel.particle,
              { transform: [{ translateX: p.x }, { translateY: p.y }, { scale: p.scale }], opacity: p.opacity },
            ]}
          >
            {EMOJIS[i % EMOJIS.length]}
          </Animated.Text>
        ))}
      </View>

      <Animated.View style={[cel.content, { transform: [{ scale: titleScale }], opacity: titleOpacity }]}>
        <Text style={cel.bigEmoji}>🎉</Text>
        <Text style={cel.title}>¡Evento finalizado!</Text>

        {/* Pago del usuario actual */}
        {myPayout && (
          <View style={cel.myPayoutBox}>
            <Text style={cel.myPayoutLabel}>💰 Tu pago ha sido acreditado</Text>
            <Text style={cel.myPayoutAmount}>${myPayout.amount.toLocaleString()}</Text>
            <Text style={cel.myPayoutSub}>en tu cartera</Text>
          </View>
        )}

        {/* Cliente: cobro automático */}
        {userRole === 'client' && (
          <View style={cel.clientNoticeBox}>
            <Text style={cel.clientNoticeText}>
              💳 El pago de este evento fue procesado con Stripe. Tu saldo se libera automáticamente al finalizar.
            </Text>
          </View>
        )}

        {/* Distribución a todos (solo dueño) */}
        {isOwner && payouts.length > 0 && (
          <View style={cel.payoutsBox}>
            <Text style={cel.payoutsTitle}>Distribución del pago</Text>
            {payouts.map(p => {
              const roleLabel = p.role === 'owner' ? 'Dueño' : p.role === 'member' ? 'Integrante' : 'Invitado';
              return (
                <View key={p.id} style={cel.payoutRow}>
                  <View style={{ flex: 1 }}>
                    <Text style={cel.payoutName} numberOfLines={1}>{(p.profile as any)?.full_name ?? 'Usuario'}</Text>
                    <Text style={cel.payoutRole}>{roleLabel}</Text>
                  </View>
                  <Text style={[cel.payoutAmount, { color: p.payout_status === 'paid' ? COLORS.green : COLORS.gold }]}>
                    ${p.amount.toLocaleString()}
                  </Text>
                </View>
              );
            })}
          </View>
        )}

        {/* Mensaje genérico si no hay payouts cargados */}
        {payouts.length === 0 && !userRole && (
          <Text style={cel.sub}>El pago ha sido procesado automáticamente.{'\n'}¡Gracias por usar Daricefy!</Text>
        )}

        {isOwner && (
          <Pressable style={cel.btnExtra} onPress={onOfferExtra}>
            <Text style={cel.btnExtraText}>🎵 Ofrecer horas extra</Text>
          </Pressable>
        )}

        <Pressable style={cel.btnClose} onPress={onClose}>
          <Text style={cel.btnCloseText}>Volver al inicio</Text>
        </Pressable>
      </Animated.View>
    </View>
  );
}

const cel = StyleSheet.create({
  overlay: {
    flex: 1, backgroundColor: COLORS.bg,
    alignItems: 'center', justifyContent: 'center',
  },
  burstCenter: {
    position: 'absolute', alignItems: 'center', justifyContent: 'center',
    width: 0, height: 0, top: '40%', left: '50%',
  },
  particle: { position: 'absolute', fontSize: 26 },
  content: { alignItems: 'center', paddingHorizontal: 32 },
  bigEmoji: { fontSize: 80, marginBottom: 12 },
  title: {
    fontFamily: FONTS.title, fontSize: 34, color: COLORS.text,
    textAlign: 'center', marginBottom: 12,
  },
  sub: {
    fontFamily: FONTS.body, fontSize: 15, color: COLORS.muted2,
    textAlign: 'center', lineHeight: 24, marginBottom: 36,
  },
  btnExtra: {
    width: '100%', backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 16, alignItems: 'center', marginBottom: 12,
  },
  btnExtraText: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.bg },
  btnClose: {
    width: '100%', backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingVertical: 16, alignItems: 'center',
  },
  btnCloseText: { fontFamily: FONTS.bodyMedium, fontSize: 15, color: COLORS.muted2 },
  myPayoutBox: {
    width: '100%', backgroundColor: 'rgba(0,230,118,0.10)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)',
    padding: 18, alignItems: 'center', marginBottom: 16,
  },
  myPayoutLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, marginBottom: 4 },
  myPayoutAmount: { fontFamily: FONTS.title, fontSize: 38, color: COLORS.green },
  myPayoutSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  clientNoticeBox: {
    width: '100%', backgroundColor: 'rgba(66,133,244,0.10)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(66,133,244,0.3)',
    padding: 14, marginBottom: 20,
  },
  clientNoticeText: { fontFamily: FONTS.body, fontSize: 13, color: '#4285F4', textAlign: 'center', lineHeight: 20 },
  payoutsBox: {
    width: '100%', backgroundColor: 'rgba(255,255,255,0.04)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    padding: 14, marginBottom: 20,
  },
  payoutsTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.muted2, textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 10 },
  payoutRow: { flexDirection: 'row', alignItems: 'center', paddingVertical: 6 },
  payoutName: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text },
  payoutRole: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 1 },
  payoutAmount: { fontFamily: FONTS.bodySemiBold, fontSize: 15 },
});

export default function EventTimerScreen({ route, navigation }: any) {
  const { reservation, readOnly = false, userRole } = route.params;
  // client = readOnly + userRole 'client'; talent = readOnly + userRole 'talent'; group owner = !readOnly
  const canSeeDetails = !readOnly || userRole === 'talent';

  // Cotización en vivo (cuando route.params.reservation no trae quote)
  const [liveQuote, setLiveQuote] = useState<any>(reservation.quote ?? null);

  // Horas contratadas: cotización (live o en params) → paquete → hours_count (express/quote) → fallback 3h
  const contractHours: number = useMemo(() =>
    reservation.quote?.duration_hours ??
    liveQuote?.duration_hours ??
    reservation.package?.duration_hours ??
    (reservation.hours_count != null ? Number(reservation.hours_count) : null) ??
    3
  , [liveQuote]);

  const [elapsed, setElapsed] = useState(0);
  const [isRunning, setIsRunning] = useState(false);
  const [startedAt, setStartedAt] = useState<Date | null>(null);
  const [preEventCountdown, setPreEventCountdown] = useState('');
  const [loading, setLoading] = useState(false);
  const [paymentPending, setPaymentPending] = useState(false);
  const [paymentFailReason, setPaymentFailReason] = useState('');
  const isAlreadyDone = reservation.status === 'completed' || !!reservation.event_ended_at;
  const [showCelebration, setShowCelebration] = useState(isAlreadyDone);
  const [invitedTalents, setInvitedTalents] = useState<TocadaTalent[]>([]);
  const [payouts, setPayouts] = useState<EventPayout[]>([]);

  const [, setMemberEarning] = useState<number | null>(null);
  const [currentUserId, setCurrentUserId] = useState<string | null>(null);
  const [extraHoursAdded, setExtraHoursAdded] = useState(0);
  const [groupMemberIds, setGroupMemberIds] = useState<string[]>([]);
  const [unreadMessages, setUnreadMessages] = useState(0);
  const [showGroupConfirmModal, setShowGroupConfirmModal] = useState(false);
  const [pendingExtraRow, setPendingExtraRow] = useState<any | null>(null);
  const [showPaymentMethodModal, setShowPaymentMethodModal] = useState(false);
  const [clientPendingExtra, setClientPendingExtra] = useState<{ hours: number; price: number } | null>(null);
  const [breakType, setBreakType] = useState<string>(reservation.break_type ?? '');
  const [hasArrived, setHasArrived] = useState<boolean>(!!reservation.group_arrived_at);
  const [arrivedAt, setArrivedAt] = useState<string | null>(reservation.group_arrived_at ?? null);
  const [eventLatLng, setEventLatLng] = useState<{ lat: number; lng: number } | null>(null);
  const [showBreakModal, setShowBreakModal] = useState(false);
  const [ratingQueue, setRatingQueue]       = useState<RatingSubject[]>([]);
  const [currentRating, setCurrentRating]   = useState<RatingSubject | null>(null);
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
      .select('id, overtime_1h_price, overtime_2h_price, overtime_3h_price, duration_hours, event_type, guests_count, notes')
      .eq('id', reservation.quote_id)
      .maybeSingle()
      .then(({ data }) => { if (data) setLiveQuote(data); });
  }, []);

  // Cargar estado fresco desde DB al montar (resuelve re-navegación)
  useEffect(() => {
    supabase
      .from('reservations')
      .select('status, event_ended_at, event_started_at, group_arrived_at')
      .eq('id', reservation.id)
      .single()
      .then(({ data }) => {
        if (!data) return;
        // Restaurar llegada
        if (data.group_arrived_at) {
          setHasArrived(true);
          setArrivedAt(data.group_arrived_at);
        }
        if (data.status === 'completed' || data.event_ended_at) {
          autoFinishedRef.current = true;
          if (intervalRef.current) clearInterval(intervalRef.current);
          setIsRunning(false);
          setShowCelebration(true);
        } else if (data.event_started_at) {
          // Reanudar timer si el evento sigue en progreso (dentro del tiempo contratado)
          const elapsedSecs = Math.floor((Date.now() - new Date(data.event_started_at).getTime()) / 1000);
          if (elapsedSecs >= 0 && elapsedSecs < contractHours * 3600) {
            setStartedAt(new Date(data.event_started_at));
            setElapsed(elapsedSecs);
            setIsRunning(true);
          } else if (!readOnly && !autoFinishedRef.current && elapsedSecs >= 0) {
            // Recovery: tiempo agotado mientras la app estuvo cerrada — cerrar evento en DB
            autoFinishedRef.current = true;
            supabase.from('reservations').update({
              status: 'completed',
              finished_at: new Date().toISOString(),
              actual_duration_minutes: Math.floor(elapsedSecs / 60),
            }).eq('id', reservation.id).then(() => {
              supabase.rpc('release_group_earnings_atomic', { p_reservation_id: reservation.id });
            });
            setShowCelebration(true);
          }
        } else if (
          !readOnly &&
          !autoStartedRef.current &&
          eventDateTime !== null &&
          data.status === 'confirmed' &&
          data.group_arrived_at &&
          Date.now() >= eventDateTime.getTime() + 10 * 60 * 1000 &&
          Date.now() <= eventDateTime.getTime() + 6 * 3600 * 1000
        ) {
          // Recovery: ventana de auto-inicio pasó mientras la app estuvo cerrada
          autoStartedRef.current = true;
          confirmStart(breakType || 'B');
        }
      });
  }, []);

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
    if (readOnly || startedAt || !eventDateTime || autoStartedRef.current || !hasArrived) return;
    if (isAlreadyDone || reservation.status === 'completed') return;
    const graceMs  = 10 * 60 * 1000;   // 10 min de gracia
    const windowMs = 6 * 3600 * 1000;  // solo eventos de las últimas 6 h
    const now_ms   = Date.now();
    const eventMs  = eventDateTime.getTime();
    if (now_ms < eventMs + graceMs) return;   // todavía dentro de la gracia
    if (now_ms > eventMs + windowMs) return;  // evento viejo, no auto-iniciar
    autoStartedRef.current = true;
    confirmStart(breakType || 'B');
  }, [now, hasArrived]);


  const progressAnim = useRef(new Animated.Value(0)).current;
  const pulseAnim = useRef(new Animated.Value(1)).current;
  const glowAnim = useRef(new Animated.Value(0.3)).current;
  const noteAnims = useRef([0,1,2,3,4,5].map(() => new Animated.Value(0))).current;
  const sparkAnims = useRef(Array.from({ length: 10 }, () => new Animated.Value(0))).current;
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const sentMilestones = useRef<Set<string>>(new Set());
  const warned15MinRef  = useRef(false);
  const warned2hRef     = useRef(false);
  const autoStartedRef  = useRef(false);
  const autoStartReadyRef = useRef(false);
  const warned30MinRef = useRef(false);
  const autoFinishedRef = useRef(false);
  const breakEndWarnedSegs = useRef<Set<number>>(new Set());
  const extraHourStartWarnedSegs = useRef<Set<number>>(new Set());

  const selectedBreak = BREAK_OPTIONS.find(o => o.type === breakType);
  const breakMins = selectedBreak ? selectedBreak.breakMinutesFor(contractHours) : 0;

  // Tiempo total del evento en segundos (base + horas extra con su descanso de 15 min c/u)
  const totalSecs = selectedBreak
    ? selectedBreak.totalMinutes(contractHours) * 60 + extraHoursAdded * 75 * 60
    : contractHours * 3600 + extraHoursAdded * 75 * 60;

  // México eliminó DST en 2022. La app opera bajo horario fijo UTC-6.
  // NO quitar el offset -06:00: sin él, el parsing usa la TZ del dispositivo y rompe auto-start.
  const eventDateTime = reservation.event_date && reservation.event_time
    ? new Date(`${reservation.event_date}T${normalizeHHMM(reservation.event_time)}:00-06:00`)
    : null;

  // El grupo puede iniciar hasta 30 min antes de la hora acordada.
  // Una vez pasada la hora exacta el inicio manual se bloquea — el auto-start lo cubre.
  const canStartNow = !startedAt && eventDateTime
    ? (() => {
        const diffMs = eventDateTime.getTime() - Date.now();
        return diffMs <= 30 * 60 * 1000 && diffMs >= 0;
      })()
    : false;

  // Schedule & current segment
  const schedule = useMemo(() => {
    // México eliminó DST en 2022. La app opera bajo horario fijo UTC-6.
    const effectiveStart = startedAt ?? (
      reservation.event_date && reservation.event_time
        ? new Date(`${reservation.event_date}T${normalizeHHMM(reservation.event_time)}:00-06:00`)
        : null
    );
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

  // ── Animations ─────────────────────────────────────────────────────────
  useEffect(() => {
    if (isRunning) {
      const pulse = Animated.loop(
        Animated.sequence([
          Animated.timing(pulseAnim, { toValue: 1.03, duration: 1800, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
          Animated.timing(pulseAnim, { toValue: 1, duration: 1800, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
        ])
      );
      const glow = Animated.loop(
        Animated.sequence([
          Animated.timing(glowAnim, { toValue: 0.7, duration: 1800, useNativeDriver: true }),
          Animated.timing(glowAnim, { toValue: 0.3, duration: 1800, useNativeDriver: true }),
        ])
      );
      pulse.start();
      glow.start();
      return () => { pulse.stop(); glow.stop(); };
    } else {
      pulseAnim.setValue(1);
      glowAnim.setValue(0.3);
    }
  }, [isRunning]);

  // Orbiting musical notes animation (only while running)
  useEffect(() => {
    if (!isRunning) {
      noteAnims.forEach(a => a.setValue(0));
      return;
    }
    const durations = [4200, 5600, 3400, 4900, 6000, 3100];
    const anims = noteAnims.map((anim, i) =>
      Animated.loop(Animated.timing(anim, {
        toValue: 1, duration: durations[i],
        useNativeDriver: true, easing: Easing.linear,
      }))
    );
    anims.forEach(a => a.start());
    return () => anims.forEach(a => a.stop());
  }, [isRunning]);

  // Spark particles around the ring (while running)
  useEffect(() => {
    if (!isRunning) {
      sparkAnims.forEach(a => a.setValue(0));
      return;
    }
    const anims = sparkAnims.map((anim, i) =>
      Animated.loop(
        Animated.sequence([
          Animated.delay(i * 220),
          Animated.timing(anim, { toValue: 1, duration: 400, useNativeDriver: true, easing: Easing.out(Easing.ease) }),
          Animated.timing(anim, { toValue: 0, duration: 700, useNativeDriver: true, easing: Easing.in(Easing.quad) }),
          Animated.delay(800 + i * 60),
        ])
      )
    );
    anims.forEach(a => a.start());
    return () => anims.forEach(a => a.stop());
  }, [isRunning]);

  useEffect(() => {
    if (reservation.event_started_at) {
      const start    = new Date(reservation.event_started_at);
      const nowSecs  = Math.floor((Date.now() - start.getTime()) / 1000);
      const approxDuration = contractHours * 3600;
      const isAlreadyOver  = reservation.status === 'completed'
        || !!reservation.event_ended_at
        || nowSecs >= approxDuration;

      setStartedAt(start);
      autoFinishedRef.current = isAlreadyOver;

      if (!isAlreadyOver) {
        // Evento en curso: reanudar timer
        setIsRunning(true);
        setElapsed(nowSecs);
        startTick(start);
      }
      // Si ya terminó, dejamos showCelebration en su valor inicial (isAlreadyDone)
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
      })
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, []);

  // Contador regresivo hasta que inicie el evento (usa estado startedAt, no el prop)
  useEffect(() => {
    if (startedAt || !reservation.event_date) return;
    const tick = () => {
      // México eliminó DST en 2022. La app opera bajo horario fijo UTC-6.
      const target = new Date(`${reservation.event_date}T${normalizeHHMM(reservation.event_time)}:00-06:00`);
      const diff = target.getTime() - Date.now();
      if (diff <= 0) { setPreEventCountdown(''); return; }
      const d = Math.floor(diff / 86_400_000);
      const h = Math.floor((diff % 86_400_000) / 3_600_000);
      const m = Math.floor((diff % 3_600_000) / 60_000);
      const s = Math.floor((diff % 60_000) / 1_000);
      if (d > 0) setPreEventCountdown(`${d}d ${h}h ${String(m).padStart(2,'0')}m`);
      else setPreEventCountdown(`${h}h ${String(m).padStart(2,'0')}m ${String(s).padStart(2,'0')}s`);
    };
    tick();
    const id = setInterval(tick, 1_000);
    return () => clearInterval(id);
  }, [startedAt, reservation.event_date, reservation.event_time]);

  useEffect(() => {
    if (!reservation.event_id && !reservation.event_request_id) return;
    const q = supabase
      .from('job_invitations')
      .select('id, invited_user_id, status, proposed_payment_amount, profile:invited_user_id(full_name, avatar_url)')
      .eq('invitation_type', 'job')
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
    // Carga inicial
    supabase
      .from('extra_hours')
      .select('hours_added')
      .eq('reservation_id', reservation.id)
      .eq('status', 'accepted')
      .then(({ data }) => {
        if (data && data.length > 0) {
          const total = data.reduce((s: number, r: any) => s + (r.hours_added ?? 0), 0);
          setExtraHoursAdded(total);
        }
      });

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
          setExtraHoursAdded(prev => prev + (row.hours_added ?? 0));
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
          // Grupo aceptó: actualizar anillo para cliente + músicos vía Realtime
          setExtraHoursAdded(prev => prev + (row.hours_added ?? 0));
          setClientPendingExtra(null);
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
        setGroupMemberIds(ids);
      });
  }, []);

  // ── Aviso 15 min antes del fin → notificar al cliente ────────────────────
  useEffect(() => {
    if (!isRunning || sentMilestones.current.has('15min')) return;
    const remaining = Math.max(0, totalSecs - elapsed);
    if (remaining <= 900 && remaining > 0) {
      sentMilestones.current.add('15min');
      warned15MinRef.current = true;
      if (reservation.client_id) {
        supabase.from('notifications').insert([{
          user_id: reservation.client_id,
          type: 'reservation',
          title: '⏰ Quedan 15 minutos',
          body: '¿Quieres más tiempo? Puedes agregar horas extra desde el temporizador.',
          data: { reservation_id: reservation.id },
        }]);
      }
    }
  }, [elapsed, isRunning]);

  // ── Aviso a las 2 horas → oferta de horas extra al cliente ───────────────
  useEffect(() => {
    if (!isRunning || sentMilestones.current.has('2h') || readOnly) return;
    if (elapsed >= 7200 && contractHours > 2) {
      sentMilestones.current.add('2h');
      warned2hRef.current = true;
      if (reservation.client_id) {
        const pricePerHour = reservation.package?.price_per_hour
          ?? Math.round((reservation.total_price ?? 0) / contractHours);
        supabase.from('notifications').insert([{
          user_id: reservation.client_id,
          type: 'extra_hours_offer',
          title: '🎵 ¡Ya llevan 2 horas de música!',
          body: `¿Quieres que continúen? Puedes contratar horas extra desde $${pricePerHour.toLocaleString()}/hr.`,
          data: { reservation_id: reservation.id, price_per_hour: pricePerHour },
        }]);
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
        const pricePerHour = reservation.package?.price_per_hour
          ?? Math.round((reservation.total_price ?? 0) / contractHours);
        supabase.from('notifications').insert([{
          user_id: reservation.client_id,
          type: 'extra_hours_offer',
          title: '⏰ Quedan 30 minutos',
          body: `El evento termina pronto. ¿Quieres agregar más tiempo? Desde $${pricePerHour.toLocaleString()}/hr.`,
          data: { reservation_id: reservation.id, price_per_hour: pricePerHour },
        }]);
      }
    }
  }, [elapsed, isRunning]);

  // ── Aviso 3 min antes de que termine un descanso ─────────────────────────
  useEffect(() => {
    if (!isRunning || !currentSegment) return;
    if (currentSegment.type !== 'break') return;
    const elapsedMin = elapsed / 60;
    const remaining = currentSegment.toMin - elapsedMin;
    const segIdx = schedule.indexOf(currentSegment);
    if (remaining <= 3 && remaining > 0 && !breakEndWarnedSegs.current.has(segIdx)) {
      breakEndWarnedSegs.current.add(segIdx);
      const notifs: any[] = [];
      if (reservation.client_id) notifs.push({
        user_id: reservation.client_id, type: 'reservation',
        title: '🎵 El descanso está por terminar',
        body: 'En 3 minutos el grupo vuelve a tocar. ¡Prepárate!',
        data: { reservation_id: reservation.id },
      });
      groupMemberIds.forEach(uid => notifs.push({
        user_id: uid, type: 'reservation',
        title: '⏰ Descanso por terminar',
        body: 'En 3 minutos vuelven a tocar. ¡Afinen y prepárense!',
        data: { reservation_id: reservation.id },
      }));
      if (notifs.length) supabase.from('notifications').insert(notifs);
    }
  }, [elapsed, isRunning, currentSegment]);

  // ── Aviso cuando inicia un segmento de hora extra ────────────────────────
  useEffect(() => {
    if (!isRunning || !currentSegment || extraHoursAdded === 0) return;
    const elapsedMin = elapsed / 60;
    // Detectar segmentos de música que son hora extra (después del tiempo contratado base)
    const baseMusicMins = contractHours * 60;
    if (currentSegment.type === 'music' && currentSegment.fromMin >= baseMusicMins) {
      const segIdx = schedule.indexOf(currentSegment);
      if (!extraHourStartWarnedSegs.current.has(segIdx) && elapsedMin >= currentSegment.fromMin && elapsedMin < currentSegment.fromMin + 1) {
        extraHourStartWarnedSegs.current.add(segIdx);
        const extraNum = Math.ceil((currentSegment.fromMin - baseMusicMins) / 60) + 1;
        const notifs: any[] = [];
        if (reservation.client_id) notifs.push({
          user_id: reservation.client_id, type: 'reservation',
          title: `🎵 ¡Tu hora extra ${extraNum > 1 ? extraNum : ''} está iniciando!`,
          body: 'El grupo está listo para seguir tocando. ¡Disfrútalo!',
          data: { reservation_id: reservation.id },
        });
        groupMemberIds.forEach(uid => notifs.push({
          user_id: uid, type: 'reservation',
          title: '🔥 ¡Hora extra, a darlo todo!',
          body: 'El cliente quiere más música. ¡Están increíbles, sigan así!',
          data: { reservation_id: reservation.id },
        }));
        if (notifs.length) supabase.from('notifications').insert(notifs);
      }
    }
  }, [elapsed, isRunning, currentSegment, extraHoursAdded]);

  const fetchPayoutInfo = async () => {
    const { data } = await supabase
      .from('reservations')
      .select('payout_status, payment_status, payout_completed')
      .eq('id', reservation.id)
      .single();
    if (data) setPayoutInfo(data as any);
  };

  useEffect(() => { if (!readOnly || userRole === 'talent') fetchPayoutInfo(); }, []);

  // Cargar coordenadas exactas del evento (del cliente) desde quote o event_request
  useEffect(() => {
    const load = async () => {
      if (reservation.quote_id) {
        const { data } = await supabase
          .from('quotes')
          .select('latitude, longitude')
          .eq('id', reservation.quote_id)
          .single();
        if (data?.latitude && data?.longitude) {
          setEventLatLng({ lat: data.latitude, lng: data.longitude });
          return;
        }
      }
      if (reservation.event_request_id) {
        const { data } = await supabase
          .from('event_requests')
          .select('latitude, longitude')
          .eq('id', reservation.event_request_id)
          .single();
        if (data?.latitude && data?.longitude) {
          setEventLatLng({ lat: data.latitude, lng: data.longitude });
        }
      }
    };
    load();
  }, []);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setCurrentUserId(data.session?.user.id ?? null);
    });
  }, []);


  // Auto-stop y auto-cobro cuando se agota el tiempo de música
  useEffect(() => {
    if (!isRunning || !startedAt || totalMusicSecs === 0) return;
    if (musicElapsed >= totalMusicSecs) {
      if (intervalRef.current) clearInterval(intervalRef.current);
      setIsRunning(false);
      if (!readOnly && !autoFinishedRef.current) {
        autoFinishedRef.current = true;
        finishEvent();
      } else {
        setShowCelebration(true);
      }
    }
  }, [musicElapsed, totalMusicSecs, isRunning, startedAt]);

  const startTick = (from: Date) => {
    if (intervalRef.current) clearInterval(intervalRef.current);
    intervalRef.current = setInterval(() => {
      const diff = Math.floor((Date.now() - from.getTime()) / 1000);
      setElapsed(diff);
    }, 1000);
  };

  // ── Actions ────────────────────────────────────────────────────────────
  const handleStartPress = () => {
    if (!breakType) setShowBreakModal(true);
    else confirmStart();
  };

  const confirmStart = async (autoBreakType?: string) => {
    const startTime = new Date();  // UTC real — toISOString() guarda timestamp correcto en DB
    const effectiveBreakType = autoBreakType ?? breakType;
    setLoading(true);
    const opt = BREAK_OPTIONS.find(o => o.type === effectiveBreakType) ?? BREAK_OPTIONS[1];
    const minsBreak = opt.breakMinutesFor(contractHours);
    const minsMusic = contractHours * 60 - minsBreak;
    if (!breakType) setBreakType(opt.type);

    await supabase.from('reservations').update({
      status: 'in_progress',
      event_started_at: startTime.toISOString(),
      break_type: opt.type,
      music_minutes: minsMusic,
    }).eq('id', reservation.id);

    if (reservation.client_id) {
      await supabase.from('notifications').insert([{
        user_id: reservation.client_id,
        type: 'reservation',
        title: '🎵 ¡Tu evento ha iniciado!',
        body: `El grupo ha comenzado a tocar en tu evento del ${reservation.event_date}. ¡Disfruta!`,
        data: { reservation_id: reservation.id },
      }]);
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

  const handleArrive = async () => {
    Alert.alert('Llegué al evento ✅', '¿Confirmas que llegaste al lugar?', [
      { text: 'Cancelar', style: 'cancel' },
      {
        text: 'Confirmar',
        onPress: async () => {
          const ts = new Date().toISOString();
          const { error: arriveError } = await supabase
            .from('reservations')
            .update({ group_arrived_at: ts })
            .eq('id', reservation.id);

          if (arriveError) {
            Alert.alert('Error', `No se pudo registrar la llegada: ${arriveError.message}`);
            return;
          }

          // Actualizar estado local inmediatamente
          setHasArrived(true);
          setArrivedAt(ts);

          // Liberar 50% de las ganancias al llegar
          supabase.rpc('release_half_on_arrival', { p_reservation_id: reservation.id })
            .then(({ data, error }) => {
              if (error) console.warn('[Arrival] Error liberando 50%:', error.message);
              else if (data?.amount_released) {
                console.log('[Arrival] 50% liberado:', data.amount_released);
              }
            });

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
            if (notifErr) {
              console.warn('Notification insert error:', notifErr.message);
            }
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

          Alert.alert('¡Registrado!', 'Se notificó al cliente que llegaste.');
        },
      },
    ]);
  };

  const finishEvent = async () => {
    if (intervalRef.current) clearInterval(intervalRef.current);
    setIsRunning(false);
    setLoading(true);

    await supabase.from('reservations').update({
      status: 'completed',
      finished_at: new Date().toISOString(),
      actual_duration_minutes: Math.floor(elapsed / 60),
    }).eq('id', reservation.id);

    // Liberar el 50% restante (o 100% si no se marcó llegué previamente)
    supabase.rpc('release_group_earnings_atomic', { p_reservation_id: reservation.id })
      .then(({ data, error }) => {
        if (error) console.warn('[FinishEvent] Error liberando ganancias:', error.message);
        else if (data?.amount_released) {
          console.log('[FinishEvent] Ganancias liberadas:', data.amount_released);
        }
      });

    await fetchPayoutInfo();

    // Recargar payouts para la pantalla de celebración
    const { data: freshPayouts } = await supabase
      .from('event_payouts')
      .select('id, user_id, role, amount, payout_status, profile:user_id(full_name)')
      .eq('reservation_id', reservation.id);
    if (freshPayouts) setPayouts(freshPayouts as any);

    // Oferta de horas extra al cliente
    if (extraHoursAdded === 0 && reservation.client_id) {
      const pricePerHour = reservation.package?.price_per_hour
        ?? Math.round((reservation.total_price ?? 0) / contractHours);
      await supabase.from('notifications').insert([{
        user_id: reservation.client_id,
        type: 'extra_hours_offer',
        title: '🎵 ¿Quieres más música?',
        body: `El grupo todavía puede quedarse. Agrega horas extra desde $${pricePerHour.toLocaleString()}/hr.`,
        data: { reservation_id: reservation.id, price_per_hour: pricePerHour },
      }]);
    }

    setLoading(false);
    setShowCelebration(true);
  };


  // ── Rating queue helpers ─────────────────────────────────────────────────
  const startRatingFlow = () => {
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
      // Cliente: califica al grupo
      queue.push({
        type: 'group',
        targetId: reservation.group_id,
        targetName: reservation.group?.name ?? 'el grupo',
        reservationId: reservation.id,
      });
    }

    if (queue.length > 0) {
      setRatingQueue(queue.slice(1));
      setCurrentRating(queue[0]);
    } else {
      navigation.goBack();
    }
  };

  const advanceRatingQueue = () => {
    if (ratingQueue.length > 0) {
      setCurrentRating(ratingQueue[0]);
      setRatingQueue(prev => prev.slice(1));
    } else {
      setCurrentRating(null);
      navigation.goBack();
    }
  };

  // ── Derived state ──────────────────────────────────────────────────────
  // Durante descanso: remaining no avanza (timer pausado)
  const remaining  = Math.max(0, totalMusicSecs - musicElapsed);
  const progress   = totalMusicSecs > 0 ? Math.min(musicElapsed / totalMusicSecs, 1) : 0;
  const nearEnd    = remaining <= 900 && remaining > 0;
  const isOnBreak  = currentSegment?.type === 'break';
  const isCompleted = !isRunning && !!startedAt && musicElapsed >= totalMusicSecs;
  const time = splitTime(remaining);
  const elapsedTime = splitTime(elapsed);
  const timePercent = totalMusicSecs > 0 ? remaining / totalMusicSecs : 1;
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

  return (
    <View style={st.container}>
      <Particles />
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
          <View style={[st.rolePill, {
            backgroundColor: userRole === 'client'
              ? 'rgba(66,133,244,0.12)'
              : userRole === 'talent'
                ? 'rgba(156,39,176,0.12)'
                : 'rgba(0,230,118,0.10)',
            borderColor: userRole === 'client'
              ? 'rgba(66,133,244,0.4)'
              : userRole === 'talent'
                ? 'rgba(156,39,176,0.4)'
                : 'rgba(0,230,118,0.35)',
          }]}>
            <Text style={[st.rolePillText, {
              color: userRole === 'client' ? '#4285F4' : userRole === 'talent' ? '#9C27B0' : COLORS.green,
            }]}>
              {userRole === 'client' ? '👁️ Vista' : userRole === 'talent' ? '🎼 Músico' : '🎵 Grupo'}
            </Text>
          </View>
        </View>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={st.scroll}>

          {/* ── TIMER (siempre visible para todos) ──────────── */}
          <View style={st.timerSection}>
            {/* Glow halo */}
            {isRunning && (
              <Animated.View style={[st.outerGlow, {
                opacity: glowAnim,
                borderColor: ringColor,
                shadowColor: ringColor,
              }]} />
            )}

            {/* SVG ring + digits overlay */}
            <Animated.View style={[st.timerSvgWrap, { transform: [{ scale: pulseAnim }] }]}>
              <Svg width={320} height={320} viewBox="0 0 320 320">
                {/* Dark fill inside ring for contrast */}
                <Circle cx="160" cy="160" r={RING_R - RING_SW / 2} fill="rgba(4,4,4,0.85)" />
                {/* Track ring */}
                <Circle
                  cx="160" cy="160" r={RING_R}
                  stroke={`${ringColor}22`}
                  strokeWidth={RING_SW}
                  fill="none"
                />
                {/* Depleting arc */}
                <Circle
                  cx="160" cy="160" r={RING_R}
                  stroke={ringColor}
                  strokeWidth={RING_SW}
                  fill="none"
                  strokeDasharray={RING_CIRC}
                  strokeDashoffset={svgDashOffset}
                  strokeLinecap="round"
                  transform="rotate(-90 160 160)"
                />
              </Svg>

              {/* Orbiting musical notes (solo cuando corre) */}
              {isRunning && (['♩','♪','♫','♬','♩','♪'] as const).map((note, i) => {
                const initialDeg = i * 60;
                const rotate = noteAnims[i].interpolate({
                  inputRange: [0, 1],
                  outputRange: [`${initialDeg}deg`, `${initialDeg + 360}deg`],
                });
                const noteColor = i % 3 === 0 ? ringColor : i % 3 === 1 ? `${ringColor}99` : `${ringColor}55`;
                return (
                  <Animated.View
                    key={i}
                    style={[StyleSheet.absoluteFill, { alignItems: 'center', transform: [{ rotate }] }]}
                  >
                    <Text style={{ fontSize: 16, color: noteColor, marginTop: 4 }}>
                      {note}
                    </Text>
                  </Animated.View>
                );
              })}

              {/* Spark particles around the ring */}
              {isRunning && sparkAnims.map((anim, i) => {
                const angle = (i / 10) * 2 * Math.PI - Math.PI / 2 + (i % 2 === 0 ? 0.18 : -0.12);
                const sparkR = 157;
                const cx = 160 + sparkR * Math.cos(angle);
                const cy = 160 + sparkR * Math.sin(angle);
                const sizes = [4, 3, 5, 3, 6, 3, 5, 4, 3, 5];
                const sz = sizes[i];
                const sparkColor = i % 3 === 0 ? '#FFFFFF' : i % 3 === 1 ? ringColor : `${ringColor}BB`;
                return (
                  <Animated.View
                    key={`sp-${i}`}
                    style={{
                      position: 'absolute',
                      left: cx - sz / 2,
                      top: cy - sz / 2,
                      width: sz,
                      height: sz,
                      borderRadius: sz / 2,
                      backgroundColor: sparkColor,
                      opacity: anim,
                      transform: [{
                        scale: anim.interpolate({ inputRange: [0, 0.4, 1], outputRange: [0.1, 2.0, 0.2] }),
                      }],
                    }}
                  />
                );
              })}

              {/* Contenido central */}
              <View style={st.timerCenterOverlay}>
                {/* Badge de estado */}
                {isRunning && currentSegment && (
                  <View style={[st.segBadge, {
                    backgroundColor: isOnBreak ? 'rgba(255,152,0,0.15)' : 'rgba(0,230,118,0.12)',
                    borderColor: isOnBreak ? 'rgba(255,152,0,0.4)' : 'rgba(0,230,118,0.35)',
                  }]}>
                    {isOnBreak
                      ? <Coffee size={11} color={COLORS.orange} />
                      : <Music2 size={11} color={COLORS.green} />}
                    <Text style={[st.segBadgeText, { color: isOnBreak ? COLORS.orange : COLORS.green }]}>
                      {isOnBreak ? 'DESCANSO' : 'TOCANDO'}
                    </Text>
                  </View>
                )}
                {!startedAt && (
                  <View style={[st.segBadge, {
                    backgroundColor: 'rgba(255,179,0,0.1)',
                    borderColor: 'rgba(255,179,0,0.35)',
                  }]}>
                    <Clock size={11} color={COLORS.gold} />
                    <Text style={[st.segBadgeText, { color: COLORS.gold }]}>PRÓXIMO EVENTO</Text>
                  </View>
                )}
                {isCompleted && <Text style={st.stateLabel}>FINALIZADO</Text>}

                {/* Dígitos grandes */}
                <View style={st.timeRow}>
                  <View style={st.digitCard}>
                    <Text style={[st.timeDigit, { color: ringColor }]}>{String(time.h).padStart(2, '0')}</Text>
                    <Text style={st.timeUnit}>HR</Text>
                  </View>
                  <Text style={[st.timeSep, { color: ringColor }]}>:</Text>
                  <View style={st.digitCard}>
                    <Text style={[st.timeDigit, { color: ringColor }]}>{String(time.m).padStart(2, '0')}</Text>
                    <Text style={st.timeUnit}>MIN</Text>
                  </View>
                  <Text style={[st.timeSep, { color: ringColor }]}>:</Text>
                  <View style={st.digitCard}>
                    <Text style={[st.timeDigit, { color: ringColor }]}>{String(time.s).padStart(2, '0')}</Text>
                    <Text style={st.timeUnit}>SEG</Text>
                  </View>
                </View>

                {isRunning && (
                  <Text style={st.elapsedLabel}>{elapsedTime.full} transcurrido</Text>
                )}
                {!startedAt && reservation.event_date && (
                  <Text style={[st.elapsedLabel, { marginTop: 2 }]}>
                    {new Date(reservation.event_date + 'T12:00:00').toLocaleDateString('es-MX', { weekday: 'short', day: 'numeric', month: 'short' })}
                    {reservation.event_time ? ` · ${formatTime12h(reservation.event_time)}` : ''}
                  </Text>
                )}
                {!startedAt && reservation.event_time && preEventCountdown ? (
                  <Text style={st.elapsedLabel}>⏰ Inicia en {preEventCountdown}</Text>
                ) : null}
              </View>
            </Animated.View>

            {/* Barra de progreso */}
            <View style={st.progressBarTrack}>
              <Animated.View style={[st.progressBarFill, {
                width: progressAnim.interpolate({ inputRange: [0, 1], outputRange: ['0%', '100%'] }),
                backgroundColor: ringColor,
              }]} />
            </View>
            <Text style={st.progressText}>{Math.round(progress * 100)}% completado</Text>
          </View>


          {/* ── ROLE CONTEXT STRIP ──────────────────────────────── */}
          <View style={st.roleContextStrip}>
            {/* Left: who's viewing */}
            <View style={st.roleContextLeft}>
              <Text style={st.roleContextLabel}>
                {userRole === 'client' ? '👤 Cliente' : userRole === 'talent' ? '🎵 Músico invitado' : '🎸 Grupo'}
              </Text>
              {!readOnly && reservation.client?.full_name && (
                <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 4 }}>
                  <View style={st.clientAvatarBox}>
                    {reservation.client?.avatar_url ? (
                      <Image source={{ uri: reservation.client.avatar_url }} style={st.clientAvatarImg} />
                    ) : (
                      <Text style={st.clientAvatarInitial}>
                        {reservation.client.full_name.charAt(0).toUpperCase()}
                      </Text>
                    )}
                  </View>
                  <Text style={st.roleContextSub} numberOfLines={1}>{reservation.client.full_name}</Text>
                </View>
              )}
              {(userRole === 'client' || userRole === 'talent') && reservation.group?.name && (
                <Text style={st.roleContextSub} numberOfLines={1}>Grupo: {reservation.group.name}</Text>
              )}
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
              <View style={st.breakRow}>
                <Text style={st.breakLabel}>Tipo de descanso:</Text>
                <Text style={st.breakValue}>{selectedBreak?.label}</Text>
              </View>
              <View style={st.breakRow}>
                <Text style={st.breakLabel}>Tiempo descanso:</Text>
                <Text style={[st.breakValue, { color: COLORS.orange }]}>{formatMinutes(breakMins)}</Text>
              </View>
              <View style={st.breakRow}>
                <Text style={st.breakLabel}>Tiempo de música:</Text>
                <Text style={[st.breakValue, { color: COLORS.green }]}>{formatMinutes(contractHours * 60 - breakMins)}</Text>
              </View>
              {!readOnly && userRole !== 'talent' && !isRunning && !startedAt && (
                <Pressable onPress={() => setShowBreakModal(true)}>
                  <Text style={st.changeBreak}>Cambiar tipo de descanso →</Text>
                </Pressable>
              )}

              {/* Timeline */}
              {schedule.length > 0 && (() => {
                const elapsedMin = elapsed / 60;
                return (
                  <View style={st.scheduleSection}>
                    <Text style={st.scheduleTitle}>Horario del evento</Text>
                    {schedule.map((seg, i) => {
                      const isActive = elapsedMin >= seg.fromMin && elapsedMin < seg.toMin;
                      const isPast = elapsedMin >= seg.toMin;
                      return (
                        <View key={i} style={[
                          st.scheduleRow,
                          isActive && st.scheduleRowActive,
                          isPast && st.scheduleRowPast,
                        ]}>
                          <View style={[
                            st.scheduleIcon,
                            seg.type === 'break' ? st.scheduleIconBreak : st.scheduleIconMusic,
                            isActive && (seg.type === 'break' ? st.scheduleIconBreakActive : st.scheduleIconMusicActive),
                          ]}>
                            {seg.type === 'music'
                              ? <Music2 size={14} color={isActive ? COLORS.bg : isPast ? COLORS.muted : COLORS.green} />
                              : <Coffee size={14} color={isActive ? COLORS.bg : isPast ? COLORS.muted : COLORS.orange} />
                            }
                          </View>
                          <View style={{ flex: 1 }}>
                            <Text style={[st.scheduleLabel, isPast && st.scheduleLabelPast]}>
                              {seg.type === 'music' ? 'Tocando' : 'Descanso'}
                              {isActive && (seg.type === 'music' ? ' 🎵' : ' ☕')}
                            </Text>
                            <Text style={[st.scheduleTime, isPast && st.scheduleTimePast]}>
                              {seg.fromTime} — {seg.toTime}
                            </Text>
                          </View>
                          <Text style={[st.scheduleDuration, isPast && st.scheduleTimePast]}>
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
              <Badge label={isOnBreak ? '☕ En descanso' : '🎵 En progreso'} variant={isOnBreak ? 'orange' : 'green'} dot />
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
            {/* Mapa con pin exacto — visible para el grupo cuando el cliente pagó */}
            {!readOnly &&
              isPaid(reservation.payment_status) &&
              eventLatLng && (
              <View style={st.exactMapWrap}>
                <Text style={st.exactMapLabel}>📍 Ubicación exacta del cliente</Text>
                <MapView
                  style={st.exactMap}
                  initialRegion={{
                    latitude:      eventLatLng.lat,
                    longitude:     eventLatLng.lng,
                    latitudeDelta:  0.004,
                    longitudeDelta: 0.004,
                  }}
                  scrollEnabled={true}
                  zoomEnabled={true}
                  pitchEnabled={false}
                  rotateEnabled={false}
                >
                  <Marker coordinate={{ latitude: eventLatLng.lat, longitude: eventLatLng.lng }} />
                </MapView>
              </View>
            )}
          </View>

          {/* ── NEAR END WARNING (15 min) ────────────────────────── */}
          {nearEnd && isRunning && (() => {
            // Precios de horas extra: paquete (fijos) o cotización (variables)
            const extraPkg = reservation.package?.extra_hour_price;
            const q = liveQuote ?? reservation.quote;
            const hasQuoteExtras = q && (q.overtime_1h_price || q.overtime_2h_price || q.overtime_3h_price);

            return (
              <View style={st.warningBanner}>
                <Text style={st.warningText}>
                  ⏰ Quedan menos de 15 minutos
                </Text>

                {/* Horas extra del paquete (precio fijo) */}
                {extraPkg != null && (
                  <View style={st.extraPriceBox}>
                    <Text style={st.extraPriceTitle}>Hora extra disponible</Text>
                    <Text style={st.extraPriceValue}>${extraPkg.toLocaleString()} / hr</Text>
                  </View>
                )}

                {/* Horas extra de la cotización */}
                {hasQuoteExtras && (
                  <View style={st.extraPriceBox}>
                    <Text style={st.extraPriceTitle}>Horas extra cotizadas</Text>
                    {q.overtime_1h_price != null && (
                      <Text style={st.extraPriceLine}>1 hr extra: ${q.overtime_1h_price.toLocaleString()}</Text>
                    )}
                    {q.overtime_2h_price != null && (
                      <Text style={st.extraPriceLine}>2 hr extra: ${q.overtime_2h_price.toLocaleString()}</Text>
                    )}
                    {q.overtime_3h_price != null && (
                      <Text style={st.extraPriceLine}>3 hr extra: ${q.overtime_3h_price.toLocaleString()}</Text>
                    )}
                  </View>
                )}

                <Pressable style={st.warningBtn} onPress={() => navigation.navigate('ExtraHours', { reservation })}>
                  <Text style={st.warningBtnText}>Solicitar hora extra al cliente</Text>
                </Pressable>
              </View>
            );
          })()}

          {/* ── PUNTUALIDAD: banner pre-evento (todos los roles) ── */}
          {!startedAt && reservation.event_date && reservation.event_time && (
            <View style={st.punctualityBanner}>
              <Text style={st.punctualityIcon}>⏰</Text>
              <View style={{ flex: 1 }}>
                <Text style={st.punctualityTitle}>Puedes iniciar antes, no después</Text>
                <Text style={st.punctualitySub}>
                  {`El evento es a las ${formatTime12h(reservation.event_time)}. Puedes iniciar anticipadamente si el cliente lo solicita. Una vez pasada la hora, el inicio es automático.`}
                </Text>
              </View>
            </View>
          )}

          {/* ── ACTIONS ─────────────────────────────────────────── */}
          {readOnly ? (
            <>
              {/* Banner de llegada del grupo (visible para cliente) */}
              {userRole === 'client' && hasArrived && (
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
              {!isRunning && !startedAt && (
                <>
                  {!hasArrived && <Button label="📍 Llegué al evento" onPress={handleArrive} variant="outline" size="lg" />}
                  {!hasArrived && <View style={{ height: 10 }} />}
                  {eventDateTime && !canStartNow && (
                    <Text style={{ fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, textAlign: 'center', marginBottom: 8 }}>
                      {'⏳ Auto-inicio a las ' + (() => {
                        const g = new Date(eventDateTime.getTime() + 10 * 60 * 1000);
                        return g.toLocaleTimeString('es-MX', { hour: '2-digit', minute: '2-digit' });
                      })() + ' si no inicias antes'}
                    </Text>
                  )}
                  <Button
                    label={canStartNow ? '▶️ Iniciar evento' : '▶️ Iniciar (aún no es la hora)'}
                    onPress={handleStartPress}
                    loading={loading}
                    size="lg"
                    disabled={!canStartNow}
                  />
                </>
              )}
              {isRunning && !hasArrived && (
                <>
                  <Button label="📍 Llegué al evento" onPress={handleArrive} variant="outline" size="lg" />
                  <View style={{ height: 10 }} />
                </>
              )}
              {/* El evento finaliza automáticamente cuando se agota el tiempo */}
            </View>
          )}

          {/* ── HORAS EXTRA — cliente compra directamente ────────── */}
          {userRole === 'client' && isRunning && (() => {
            const q = liveQuote ?? reservation.quote;
            const opts = [
              q?.overtime_1h_price != null ? { hours: 1, price: q.overtime_1h_price } : null,
              q?.overtime_2h_price != null ? { hours: 2, price: q.overtime_2h_price } : null,
              q?.overtime_3h_price != null ? { hours: 3, price: q.overtime_3h_price } : null,
            ].filter(Boolean) as { hours: number; price: number }[];

            if (opts.length === 0) return null;

            const handleBuyExtra = async (hours: number, price: number) => {
              Alert.alert(
                `Solicitar +${hours}h extra`,
                `Enviarás una solicitud al grupo para agregar ${hours}h más por $${price.toLocaleString()}. El grupo debe aceptar antes de extender el tiempo.`,
                [
                  { text: 'Cancelar', style: 'cancel' },
                  {
                    text: 'Solicitar',
                    onPress: async () => {
                      const commissionAmt = Math.round(price * 0.10 * 100) / 100;
                      const ownerEarnings = price - commissionAmt;
                      const { error } = await supabase.from('extra_hours').insert([{
                        reservation_id: reservation.id,
                        hours_added: hours,
                        price_per_hour: Math.round(price / hours),
                        total_extra_cost: price,
                        platform_commission: commissionAmt,
                        group_extra_earnings: ownerEarnings,
                        status: 'awaiting_group_confirmation',
                      }]);
                      if (error) { Alert.alert('Error', error.message); return; }
                      setClientPendingExtra({ hours, price });
                      // Notificar al grupo para que abra el temporizador
                      const notifs = groupMemberIds.map(uid => ({
                        user_id: uid, type: 'reservation',
                        title: '🕐 Solicitud de hora extra',
                        body: `El cliente solicitó ${hours}h extra por $${price.toLocaleString()} MXN.`,
                        data: { reservation_id: reservation.id },
                      }));
                      if (notifs.length) supabase.from('notifications').insert(notifs).then();
                    },
                  },
                ]
              );
            };

            return (
              <>
                {/* Anti-bypass warning */}
                <View style={st.antiBypassBanner}>
                  <Text style={st.antiBypassText}>
                    ⚠️ Para tu seguridad y garantía de servicio, solicita tus horas extra aquí, a través de la app. Los pagos fuera de la plataforma no están cubiertos por nuestra garantía de calidad.
                  </Text>
                </View>

                <View style={st.clientExtraCard}>
                  <Text style={st.clientExtraTitle}>¿Quieres más tiempo? 🎵</Text>
                  <Text style={st.clientExtraSub}>Solicita horas extra — el grupo confirma y el anillo se actualiza automáticamente.</Text>

                  {clientPendingExtra ? (
                    <View style={st.clientExtraPending}>
                      <Text style={st.clientExtraPendingIcon}>⏳</Text>
                      <Text style={st.clientExtraPendingText}>
                        Solicitud de +{clientPendingExtra.hours}h enviada al grupo.{'\n'}Esperando confirmación…
                      </Text>
                    </View>
                  ) : (
                    <View style={st.clientExtraOpts}>
                      {opts.map(opt => (
                        <Pressable
                          key={opt.hours}
                          style={[st.clientExtraOpt, extraHoursAdded >= opt.hours && st.clientExtraOptDone]}
                          onPress={() => extraHoursAdded < opt.hours && handleBuyExtra(opt.hours, opt.price)}
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
            );
          })()}

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

                  {/* ── Desglose financiero ── */}
                  <View style={st.commissionBox}>
                    <Text style={st.clientReqTitle}>Distribución de ganancias</Text>

                    {/* Total pagado por el cliente */}
                    {reservation.total_price != null && (
                    <View style={st.commRow}>
                      <Text style={st.commLabel}>Total del evento</Text>
                      <Text style={[st.commValue, { color: COLORS.text }]}>
                        ${reservation.total_price.toLocaleString()}
                      </Text>
                    </View>
                    )}

                    {/* Comisión de la plataforma */}
                    {reservation.commission_amount != null && (
                      <View style={st.commRow}>
                        <View>
                          <Text style={st.commLabel}>Comisión plataforma</Text>
                          <Text style={st.commSub}>Servicio de la app</Text>
                        </View>
                        <Text style={[st.commValue, { color: COLORS.orange }]}>
                          - ${reservation.commission_amount.toLocaleString()}
                        </Text>
                      </View>
                    )}

                    {/* Ganancia neta del grupo */}
                    <View style={[st.commRow, st.commNetRow]}>
                      <Text style={st.commNetLabel}>Ganancia del grupo</Text>
                      <Text style={st.commNetValue}>
                        ${(reservation.group_earnings ?? (reservation.total_price != null ? reservation.total_price - (reservation.commission_amount ?? 0) : null))?.toLocaleString() ?? '—'}
                      </Text>
                    </View>

                    {/* Por integrante */}
                    {payouts.length > 0 ? (
                      <>
                        <Text style={st.commMemberTitle}>Por integrante</Text>
                        {payouts.map(p => {
                          const roleLabel =
                            p.role === 'owner'  ? 'Dueño del grupo' :
                            p.role === 'member' ? 'Integrante' : 'Invitado';
                          const statusColor = p.payout_status === 'paid' ? COLORS.green : p.payout_status === 'failed' ? '#FF5252' : COLORS.gold;
                          return (
                            <View key={p.id} style={st.memberDistRow}>
                              <View style={{ flex: 1 }}>
                                <Text style={st.memberDistName} numberOfLines={1}>
                                  {(p.profile as any)?.full_name ?? 'Usuario'}
                                </Text>
                                <Text style={st.memberDistRole}>{roleLabel}</Text>
                              </View>
                              <View style={{ alignItems: 'flex-end' }}>
                                <Text style={[st.memberDistAmount, { color: statusColor }]}>
                                  ${p.amount.toLocaleString()}
                                </Text>
                                <Text style={[st.memberDistStatus, { color: statusColor }]}>
                                  {p.payout_status === 'paid' ? 'Pagado' : p.payout_status === 'failed' ? 'Fallido' : 'Pendiente'}
                                </Text>
                              </View>
                            </View>
                          );
                        })}
                      </>
                    ) : invitedTalents.filter(t => t.status === 'accepted').length > 0 ? (
                      <>
                        <Text style={st.commMemberTitle}>Por integrante (estimado)</Text>
                        <View style={st.memberDistRow}>
                          <View style={{ flex: 1 }}>
                            <Text style={st.memberDistName}>Dueño del grupo</Text>
                          </View>
                          <Text style={[st.memberDistAmount, { color: COLORS.gold }]}>
                            {(() => {
                              const base = reservation.group_earnings ?? reservation.total_price ?? 0;
                              const paid = invitedTalents.filter(t => t.status === 'accepted').reduce((s, t) => s + (t.proposed_payment_amount ?? 0), 0);
                              return `$${Math.max(0, base - paid).toLocaleString()}`;
                            })()}
                          </Text>
                        </View>
                        {invitedTalents.filter(t => t.status === 'accepted' && t.proposed_payment_amount != null).map(t => (
                          <View key={t.id} style={st.memberDistRow}>
                            <View style={{ flex: 1 }}>
                              <Text style={st.memberDistName} numberOfLines={1}>
                                {(t.profile as any)?.full_name ?? 'Talento'}
                              </Text>
                              <Text style={st.memberDistRole}>Invitado</Text>
                            </View>
                            <Text style={[st.memberDistAmount, { color: COLORS.gold }]}>
                              ${t.proposed_payment_amount!.toLocaleString()}
                            </Text>
                          </View>
                        ))}
                      </>
                    ) : null}
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
        {(hasArrived || isRunning) && !reservation.event_ended_at && (
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
                  {unreadMessages > 9 ? '9+' : unreadMessages}
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

                  {/* Desglose de comisión */}
                  <View style={st.extraCommBox}>
                    <Text style={st.extraCommTitle}>💰 Desglose de la hora extra</Text>
                    <View style={st.extraCommRow}>
                      <Text style={st.extraCommLabel}>Total cobrado al cliente</Text>
                      <Text style={[st.extraCommValue, { color: COLORS.text }]}>${total.toLocaleString()}</Text>
                    </View>
                    <View style={st.extraCommRow}>
                      <Text style={st.extraCommLabel}>Comisión plataforma (10%)</Text>
                      <Text style={[st.extraCommValue, { color: COLORS.orange }]}>- ${comm.toLocaleString()}</Text>
                    </View>
                    <View style={[st.extraCommRow, { borderTopWidth: 1, borderTopColor: COLORS.border, paddingTop: 8, marginTop: 4 }]}>
                      <Text style={[st.extraCommLabel, { fontFamily: FONTS.bodySemiBold, color: COLORS.text }]}>Para el grupo</Text>
                      <Text style={[st.extraCommValue, { color: COLORS.green, fontSize: 18 }]}>${groupCut.toLocaleString()}</Text>
                    </View>
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
                      const { error } = await supabase.rpc('group_confirm_extra_hours', {
                        p_extra_id: pendingExtraRow.id,
                      });
                      if (error) {
                        Alert.alert('Error', 'No se pudo confirmar. Intenta de nuevo.');
                        return;
                      }
                      // Acreditar ganancias inmediatamente (97% grupo / 3% plataforma)
                      supabase.rpc('credit_extra_hour_earnings', {
                        p_reservation_id: reservation.id,
                        p_extra_amount: total,
                      }).then(({ error: rpcErr }) => {
                        if (rpcErr) console.warn('credit_extra_hour_earnings:', rpcErr.message);
                      });
                      // Notificar al cliente que fue aceptado
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
                    }}
                  >
                    <Text style={st.confirmBtnText}>✅ Aceptar y extender timer</Text>
                  </Pressable>

                  <Pressable
                    style={[st.cancelBreakBtn, { marginTop: 8 }]}
                    onPress={async () => {
                      setShowGroupConfirmModal(false);
                      // Marcar como rechazado en DB
                      await supabase.from('extra_hours')
                        .update({ status: 'rejected' })
                        .eq('id', pendingExtraRow.id);
                      if (reservation.client_id) {
                        supabase.from('notifications').insert([{
                          user_id: reservation.client_id,
                          type: 'reservation',
                          title: '❌ Hora extra no disponible',
                          body: 'El grupo no puede extender el servicio en este momento.',
                          data: { reservation_id: reservation.id },
                        }]).then();
                      }
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

      {/* ── CELEBRACIÓN: EVENTO FINALIZADO ───────────────────── */}
      <Modal visible={showCelebration} transparent={false} animationType="fade">
        <CelebrationOverlay
          isOwner={!readOnly}
          userRole={userRole}
          payouts={payouts}
          currentUserId={currentUserId}
          onOfferExtra={() => {
            setShowCelebration(false);
            navigation.navigate('ExtraHours', { reservation });
          }}
          onClose={() => {
            setShowCelebration(false);
            startRatingFlow();
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
          <View style={st.modal}>
            <Text style={st.modalTitle}>Tipo de descanso</Text>
            <Text style={st.modalSub}>
              Pregunta al cliente cuál prefiere y selecciónalo aquí.{'\n'}
              El tiempo de música se actualizará automáticamente.
            </Text>

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

            <Pressable
              style={[st.confirmBtn, !breakType && { opacity: 0.4 }]}
              onPress={() => setShowBreakModal(false)}
              disabled={!breakType}
            >
              <Text style={st.confirmBtnText}>Confirmar</Text>
            </Pressable>
            <Pressable
              style={st.cancelBreakBtn}
              onPress={() => setShowBreakModal(false)}
            >
              <Text style={st.cancelBreakBtnText}>Cancelar</Text>
            </Pressable>
          </View>
        </View>
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
  scroll: { paddingHorizontal: 16, paddingVertical: 20, alignItems: 'center' },

  // ── Timer SVG Arc ──────────────────────────────────────────
  timerSection: { alignItems: 'center', marginBottom: 24, width: '100%' },
  outerGlow: {
    position: 'absolute', top: -10, width: 340, height: 340, borderRadius: 170,
    borderWidth: 1.5, shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.7, shadowRadius: 40, elevation: 0,
  },

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
    paddingHorizontal: 16,
  },
  progressBarTrack: {
    width: '100%', height: 4, borderRadius: 2,
    backgroundColor: COLORS.border, marginBottom: 8, overflow: 'hidden',
  },
  progressBarFill: { height: 4, borderRadius: 2 },

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
  timeDigit: { fontFamily: FONTS.title, fontSize: 38, lineHeight: 42 },
  timeUnit: {
    fontFamily: FONTS.body, fontSize: 7, color: COLORS.muted,
    letterSpacing: 1.2, marginTop: -2,
  },
  timeSep: { fontFamily: FONTS.title, fontSize: 26, lineHeight: 42, marginHorizontal: 1, marginBottom: 8 },

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
  scheduleRowActive: { backgroundColor: 'rgba(0,230,118,0.08)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)' },
  scheduleRowPast: { opacity: 0.5 },
  scheduleIcon: {
    width: 30, height: 30, borderRadius: 15, alignItems: 'center', justifyContent: 'center',
  },
  scheduleIconMusic: { backgroundColor: 'rgba(0,230,118,0.12)' },
  scheduleIconBreak: { backgroundColor: 'rgba(255,152,0,0.12)' },
  scheduleIconMusicActive: { backgroundColor: COLORS.green },
  scheduleIconBreakActive: { backgroundColor: COLORS.orange },
  scheduleLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  scheduleLabelPast: { color: COLORS.muted },
  scheduleTime: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1 },
  scheduleTimePast: { color: COLORS.muted },
  scheduleDuration: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  selectBreakBtn: {
    width: '100%', flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.green, padding: 14, marginBottom: 14,
  },
  selectBreakText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.green },

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
    backgroundColor: COLORS.greenMuted, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 10, paddingHorizontal: 14, marginTop: 6,
  },
  mapBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, flex: 1 },
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
  readOnlyText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: '#9C27B0', marginBottom: 2 },
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
  clientExtraOptPrice: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  clientExtraOptDoneLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 11, color: COLORS.green, marginTop: 4 },

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
  roleContextHours: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.green },
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
  exactMapWrap:  { marginTop: 12, borderRadius: RADIUS.lg, overflow: 'hidden' },
  exactMapLabel: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2, marginBottom: 6 },
  exactMap:      { width: '100%', height: 180, borderRadius: RADIUS.lg },
});
