import { ArrowLeft, Clock, Coffee, Info, MapPin, MessageCircle, Music2, X } from 'lucide-react-native';
import React, { useEffect, useMemo, useRef, useState } from 'react';
import {
  Animated,
  Easing,
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import Svg, { Circle } from 'react-native-svg';
import { SafeAreaView } from 'react-native-safe-area-context';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Particles from '../../components/ui/Particles';
import { generateBreakSchedule } from '../../utils/calculations';
import { maxExtraHoursAfter } from '../../utils/logistics';

// ── Ring constants (igual que EventTimerScreen) ─────────────────────────────
const RING_R  = 130;
const RING_SW = 12;
const RING_CIRC = 2 * Math.PI * RING_R;

function splitTime(secs: number) {
  const h = Math.floor(secs / 3600);
  const m = Math.floor((secs % 3600) / 60);
  const s = secs % 60;
  return { h, m, s, full: `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` };
}

const BREAK_LABELS: Record<string, string> = {
  A: '15 min por hora',
  B: '15 min a la mitad',
  C: '20 min a la mitad',
  D: 'Sin descanso',
};

// ── Extra hours offer modal ─────────────────────────────────────────────────

function ExtraHoursModal({
  visible,
  pricePerHour,
  awaiting,
  onClose,
  onConfirm,
}: {
  visible: boolean;
  pricePerHour: number;
  awaiting: boolean;
  onClose: () => void;
  onConfirm: (hours: number, total: number) => void;
}) {
  const options = [1, 2, 3];
  return (
    <Modal visible={visible} transparent animationType="slide">
      <View style={xh.backdrop}>
        <View style={xh.sheet}>
          {awaiting ? (
            <>
              <Text style={xh.title}>⏳ Esperando al grupo</Text>
              <Text style={xh.sub}>
                Tu solicitud fue enviada.{'\n'}
                El grupo debe confirmar que continuará el servicio.
              </Text>
              <View style={xh.awaitingBox}>
                <Text style={xh.awaitingMsg}>
                  💬 Dile al grupo:{'\n'}
                  <Text style={{ fontFamily: 'DMSans_600SemiBold' }}>"Confírmalo en tu celular para continuar"</Text>
                </Text>
              </View>
              <Pressable style={xh.cancel} onPress={onClose}>
                <Text style={xh.cancelText}>Cerrar</Text>
              </Pressable>
            </>
          ) : (
            <>
              <Text style={xh.title}>⏰ Tu evento está por terminar</Text>
              <Text style={xh.sub}>¿Quieres agregar más tiempo?</Text>
              <View style={xh.pushBox}>
                <Text style={xh.pushMsg}>
                  Para continuar el servicio debes agregar tiempo desde la app.{'\n'}
                  Esto asegura tu evento y el tiempo en vivo.
                </Text>
              </View>
              {options.map(h => (
                <Pressable
                  key={h}
                  style={xh.row}
                  onPress={() => onConfirm(h, h * pricePerHour)}
                >
                  <View>
                    <Text style={xh.rowHrs}>+{h} hora{h > 1 ? 's' : ''}</Text>
                    <Text style={xh.rowPriceLabel}>${pricePerHour.toLocaleString()} / hr</Text>
                  </View>
                  <View style={xh.payBtn}>
                    <Text style={xh.payBtnText}>${(h * pricePerHour).toLocaleString()}</Text>
                    <Text style={xh.payBtnSub}>Solicitar</Text>
                  </View>
                </Pressable>
              ))}
              <Pressable style={xh.cancel} onPress={onClose}>
                <Text style={xh.cancelText}>Ahora no</Text>
              </Pressable>
            </>
          )}
        </View>
      </View>
    </Modal>
  );
}

const xh = StyleSheet.create({
  backdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.7)', justifyContent: 'flex-end' },
  sheet: { backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24, padding: 28, paddingBottom: 40, gap: 0 },
  title: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, marginBottom: 6 },
  sub: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, marginBottom: 20, lineHeight: 21 },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', backgroundColor: COLORS.card2, borderRadius: RADIUS.lg, padding: 16, marginBottom: 10, borderWidth: 1, borderColor: COLORS.border },
  rowHrs: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  rowPriceLabel: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  payBtn: { backgroundColor: COLORS.green, borderRadius: 12, paddingHorizontal: 18, paddingVertical: 10, alignItems: 'center' },
  payBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },
  payBtnSub: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.bg, marginTop: 1 },
  cancel: { alignItems: 'center', marginTop: 8, padding: 12 },
  cancelText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
  pushBox: {
    backgroundColor: 'rgba(0,230,118,0.07)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.2)',
    padding: 12, marginBottom: 16,
  },
  pushMsg: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 19 },
  awaitingBox: {
    backgroundColor: 'rgba(255,179,0,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.25)',
    padding: 14, marginBottom: 16, marginTop: 4,
  },
  awaitingMsg: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.gold, lineHeight: 20, textAlign: 'center' },
});

// ── Main screen ──────────────────────────────────────────────────────────────

export default function LiveEventScreen({ route, navigation }: any) {
  const { reservation: initialReservation } = route.params;
  const [reservation, setReservation] = useState(initialReservation);

  const contractHours: number =
    reservation.quote?.duration_hours ??
    (reservation.hours_count != null ? Number(reservation.hours_count) : null) ??
    3;

  const breakType = reservation.break_type ?? 'D';

  const [elapsed,  setElapsed]  = useState(0);
  const [isRunning, setIsRunning] = useState(false);
  const [showExtraModal, setShowExtraModal] = useState(false);
  const [showLegalNotice, setShowLegalNotice] = useState(false);
  const [pricePerHourState, setPricePerHour] = useState<number | null>(null);
  // Con OTRA tocada del grupo después ese día no hay horas extra posibles
  const [extraHoursCap, setExtraHoursCap] = useState<number>(Infinity);
  // Horas extra confirmadas (extienden el timer)
  const [extraHoursConfirmed, setExtraHoursConfirmed] = useState(0);
  // Estado del flujo de doble confirmación
  const [awaitingGroupConfirm, setAwaitingGroupConfirm] = useState(false);
  // Feedback post-evento
  const [feedbackSent, setFeedbackSent] = useState(false);
  const [reportingProblem, setReportingProblem] = useState(false);
  const [issueText, setIssueText] = useState('');
  const warned15MinRef = useRef(false);

  const intervalRef  = useRef<ReturnType<typeof setInterval> | null>(null);
  const notifSubRef  = useRef<any>(null);
  const pulseAnim   = useRef(new Animated.Value(1)).current;
  const glowAnim    = useRef(new Animated.Value(0.3)).current;
  const noteAnims   = useRef(Array.from({ length: 6 }, () => new Animated.Value(0))).current;

  // ── Break schedule ─────────────────────────────────────────────────────────
  const schedule = useMemo(() => {
    if (!reservation.event_started_at || !breakType) return [];
    return generateBreakSchedule(new Date(reservation.event_started_at), contractHours, breakType);
  }, [reservation.event_started_at, breakType, contractHours]);

  const totalMusicSecs = useMemo(() => {
    return schedule.filter(s => s.type === 'music').reduce((acc, s) => acc + (s.toMin - s.fromMin) * 60, 0);
  }, [schedule]);

  const originalTotalSecs = contractHours * 3600;
  const totalSecs = (contractHours + extraHoursConfirmed) * 3600;

  // music elapsed (excluding breaks)
  const musicElapsed = useMemo(() => {
    if (!schedule.length) return elapsed;
    const elapsedMin = elapsed / 60;
    return schedule
      .filter(s => s.type === 'music')
      .reduce((acc, s) => {
        if (elapsedMin >= s.toMin) return acc + (s.toMin - s.fromMin) * 60;
        if (elapsedMin >= s.fromMin) return acc + (elapsedMin - s.fromMin) * 60;
        return acc;
      }, 0);
  }, [elapsed, schedule]);

  const currentSegment = useMemo(() => {
    const elapsedMin = elapsed / 60;
    return schedule.find(seg => elapsedMin >= seg.fromMin && elapsedMin < seg.toMin) ?? null;
  }, [elapsed, schedule]);

  // ── Timer ──────────────────────────────────────────────────────────────────
  useEffect(() => {
    if (reservation.event_started_at) {
      const start = new Date(reservation.event_started_at);
      const diff = Math.floor((Date.now() - start.getTime()) / 1000);
      setElapsed(Math.max(0, diff));
      setIsRunning(true);
      intervalRef.current = setInterval(() => {
        const d = Math.floor((Date.now() - start.getTime()) / 1000);
        setElapsed(d);
        if (d >= totalSecs && intervalRef.current) {
          clearInterval(intervalRef.current);
          setIsRunning(false);
        }
      }, 1000);
    }
    return () => { if (intervalRef.current) clearInterval(intervalRef.current); };
  }, [reservation.event_started_at]);

  // ── Supabase realtime ──────────────────────────────────────────────────────
  useEffect(() => {
    const sub = supabase
      .channel(`live-client-${reservation.id}`)
      .on('postgres_changes', {
        event: 'UPDATE',
        schema: 'public',
        table: 'reservations',
        filter: `id=eq.${reservation.id}`,
      }, (payload: any) => {
        const upd = payload.new;
        setReservation((prev: any) => ({ ...prev, ...upd }));
        if (upd.event_started_at && !isRunning) {
          const start = new Date(upd.event_started_at);
          setIsRunning(true);
          if (intervalRef.current) clearInterval(intervalRef.current);
          intervalRef.current = setInterval(() => {
            const d = Math.floor((Date.now() - start.getTime()) / 1000);
            setElapsed(d);
          }, 1000);
        }
        if (upd.event_ended_at || upd.status === 'completed') {
          if (intervalRef.current) clearInterval(intervalRef.current);
          setIsRunning(false);
        }
        // Oferta de horas extra enviada por el grupo
        if (upd.extra_hours_offered && !showExtraModal) {
          setShowExtraModal(true);
        }
      })
      .subscribe();
    return () => { supabase.removeChannel(sub); };
  }, []);

  // ── Escuchar notificaciones de oferta de horas extra ──────────────────────
  useEffect(() => {
    let userId: string | null = null;
    supabase.auth.getSession().then(({ data }) => {
      userId = data.session?.user.id ?? null;
      if (!userId) return;
      const notifSub = supabase
        .channel(`live-notifs-${reservation.id}`)
        .on('postgres_changes', {
          event: 'INSERT',
          schema: 'public',
          table: 'notifications',
          filter: `user_id=eq.${userId}`,
        }, (payload: any) => {
          const n = payload.new;
          if (n.type === 'extra_hours_offer' && n.data?.reservation_id === reservation.id) {
            if (n.data?.price_per_hour) {
              setPricePerHour(n.data.price_per_hour);
            }
            setShowExtraModal(true);
          }
        })
        .subscribe();
      notifSubRef.current = notifSub;
    });
    return () => {
      if (notifSubRef.current) supabase.removeChannel(notifSubRef.current);
    };
  }, []);

  // ¿El grupo tiene otra tocada después ese día? → no ofrecer horas extra
  useEffect(() => {
    maxExtraHoursAfter({
      groupId:       reservation.group_id,
      eventDate:     reservation.event_date,
      eventTime:     reservation.event_time,
      durationHours: contractHours,
    }).then(setExtraHoursCap);
  }, []);

  // ── Auto-trigger modal a 15 min del fin (solo si caben horas extra) ───────
  useEffect(() => {
    if (!isRunning || warned15MinRef.current || extraHoursCap <= 0) return;
    const remaining = Math.max(0, totalSecs - elapsed);
    if (remaining <= 900 && remaining > 0) {
      warned15MinRef.current = true;
      setShowExtraModal(true);
    }
  }, [elapsed, isRunning, totalSecs, extraHoursCap]);

  // ── Realtime: escuchar horas extra aceptadas por el grupo ─────────────────
  useEffect(() => {
    const ch = supabase
      .channel(`extra-hours-client-${reservation.id}`)
      .on('postgres_changes', {
        event: 'UPDATE',
        schema: 'public',
        table: 'extra_hours',
        filter: `reservation_id=eq.${reservation.id}`,
      }, (payload: any) => {
        if (payload.new.status === 'accepted') {
          setExtraHoursConfirmed(prev => prev + (payload.new.hours_added ?? 0));
          setAwaitingGroupConfirm(false);
        }
      })
      .subscribe();
    return () => { supabase.removeChannel(ch); };
  }, []);

  // ── Animations ─────────────────────────────────────────────────────────────
  useEffect(() => {
    if (!isRunning) return;
    const pulse = Animated.loop(Animated.sequence([
      Animated.timing(pulseAnim, { toValue: 1.03, duration: 1800, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
      Animated.timing(pulseAnim, { toValue: 1,    duration: 1800, easing: Easing.inOut(Easing.ease), useNativeDriver: true }),
    ]));
    const glow = Animated.loop(Animated.sequence([
      Animated.timing(glowAnim, { toValue: 0.7, duration: 1800, useNativeDriver: true }),
      Animated.timing(glowAnim, { toValue: 0.3, duration: 1800, useNativeDriver: true }),
    ]));
    pulse.start(); glow.start();
    const noteLoops = noteAnims.map(a =>
      Animated.loop(Animated.timing(a, { toValue: 1, duration: 8000 + Math.random() * 4000, easing: Easing.linear, useNativeDriver: true }))
    );
    noteLoops.forEach(l => l.start());
    return () => { pulse.stop(); glow.stop(); noteLoops.forEach(l => l.stop()); };
  }, [isRunning]);

  // ── Derived ─────────────────────────────────────────────────────────────────
  const remaining     = Math.max(0, totalMusicSecs > 0 ? totalMusicSecs - musicElapsed : totalSecs - elapsed);
  const progress      = totalMusicSecs > 0 ? Math.min(musicElapsed / totalMusicSecs, 1) : Math.min(elapsed / totalSecs, 1);
  const svgDashOffset = RING_CIRC * progress;
  const isCompleted   = reservation.status === 'completed' || !!reservation.event_ended_at;
  const isOnBreak     = currentSegment?.type === 'break';
  const groupName     = reservation.group?.name ?? 'Tu grupo';
  const time          = splitTime(remaining);
  const elapsedTime   = splitTime(elapsed);
  const timePercent   = totalMusicSecs > 0 ? remaining / totalMusicSecs : 1;
  const ringColor     = isCompleted
    ? COLORS.muted
    : isOnBreak
      ? COLORS.orange
      : timePercent < 0.1
        ? '#FF5252'
        : timePercent < 0.25
          ? COLORS.orange
          : COLORS.green;

  const pricePerHour = pricePerHourState
    ?? Math.round((reservation.total_price ?? 0) / contractHours);

  return (
    <View style={s.container}>
      <Particles />
      <SafeAreaView style={{ flex: 1 }}>

        {/* Header */}
        <View style={s.header}>
          <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
            <ArrowLeft size={20} color={COLORS.text} />
          </Pressable>
          <Text style={s.headerTitle}>Evento en vivo</Text>
          <Pressable style={s.backBtn} onPress={() => setShowLegalNotice(true)}>
            <Info size={20} color={COLORS.muted2} />
          </Pressable>
        </View>

        <ScrollView showsVerticalScrollIndicator={false} contentContainerStyle={s.scroll}>

          {/* Live badge */}
          <View style={s.liveBadgeRow}>
            {isRunning ? (
              <View style={{ alignItems: 'center', gap: 6 }}>
                <View style={[s.liveBadge, isOnBreak && s.liveBadgeBreak]}>
                  <Animated.View style={[s.liveDot, isOnBreak && { backgroundColor: COLORS.orange }]} />
                  <Text style={[s.liveBadgeText, isOnBreak && { color: COLORS.orange }]}>
                    {isOnBreak ? 'EN DESCANSO' : 'EN VIVO'}
                  </Text>
                </View>
                {elapsed > originalTotalSecs && (
                  <View style={s.overContractBadge}>
                    <Text style={s.overContractText}>
                      {extraHoursConfirmed > 0 ? '⏱ EXTENSIÓN' : '⚠️ FUERA DE CONTRATO'}
                    </Text>
                  </View>
                )}
              </View>
            ) : isCompleted ? (
              <View style={[s.liveBadge, { backgroundColor: 'rgba(136,136,136,0.12)', borderColor: 'rgba(136,136,136,0.3)' }]}>
                <Text style={[s.liveBadgeText, { color: COLORS.muted }]}>FINALIZADO</Text>
              </View>
            ) : (
              <View style={[s.liveBadge, { backgroundColor: 'rgba(255,179,0,0.12)', borderColor: 'rgba(255,179,0,0.3)' }]}>
                <Text style={[s.liveBadgeText, { color: COLORS.gold }]}>PRÓXIMO</Text>
              </View>
            )}
          </View>

          {/* Group name */}
          <View style={s.groupRow}>
            <Music2 size={18} color={COLORS.green} />
            <Text style={s.groupName}>{groupName}</Text>
          </View>

          {/* ── SVG arc ring ─────────────────────────────────────────── */}
          <View style={s.timerSection}>

            {isRunning && (
              <Animated.View style={[s.outerGlow, { opacity: glowAnim, borderColor: ringColor, shadowColor: ringColor }]} />
            )}

            <Animated.View style={[s.timerSvgWrap, { transform: [{ scale: pulseAnim }] }]}>
              <Svg width={320} height={320} viewBox="0 0 320 320">
                <Circle cx="160" cy="160" r={RING_R - RING_SW / 2} fill="rgba(4,4,4,0.85)" />
                <Circle cx="160" cy="160" r={RING_R} stroke={`${ringColor}22`} strokeWidth={RING_SW} fill="none" />
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

              {/* Orbiting notes */}
              {isRunning && (['♩','♪','♫','♬','♩','♪'] as const).map((note, i) => {
                const rotate = noteAnims[i].interpolate({
                  inputRange: [0, 1],
                  outputRange: [`${i * 60}deg`, `${i * 60 + 360}deg`],
                });
                return (
                  <Animated.View
                    key={i}
                    style={[StyleSheet.absoluteFill, { alignItems: 'center', transform: [{ rotate }] }]}
                    pointerEvents="none"
                  >
                    <Text style={{ fontSize: 16, color: i % 2 === 0 ? ringColor : `${ringColor}66`, marginTop: 4 }}>
                      {note}
                    </Text>
                  </Animated.View>
                );
              })}

              {/* Center content */}
              <View style={s.timerCenterOverlay}>
                {isRunning && currentSegment && (
                  <View style={[s.segBadge, {
                    backgroundColor: isOnBreak ? 'rgba(255,152,0,0.15)' : 'rgba(0,230,118,0.12)',
                    borderColor:     isOnBreak ? 'rgba(255,152,0,0.4)' : 'rgba(0,230,118,0.35)',
                  }]}>
                    {isOnBreak
                      ? <Coffee size={11} color={COLORS.orange} />
                      : <Music2 size={11} color={COLORS.green} />}
                    <Text style={[s.segBadgeText, { color: isOnBreak ? COLORS.orange : COLORS.green }]}>
                      {isOnBreak ? 'DESCANSO' : 'TOCANDO'}
                    </Text>
                  </View>
                )}
                {!isRunning && !isCompleted && (
                  <View style={[s.segBadge, { backgroundColor: 'rgba(255,179,0,0.1)', borderColor: 'rgba(255,179,0,0.35)' }]}>
                    <Clock size={11} color={COLORS.gold} />
                    <Text style={[s.segBadgeText, { color: COLORS.gold }]}>PRÓXIMO EVENTO</Text>
                  </View>
                )}
                {isCompleted && <Text style={s.stateLabel}>FINALIZADO</Text>}

                <View style={s.timeRow}>
                  <View style={s.digitCard}>
                    <Text style={[s.timeDigit, { color: ringColor }]}>{String(time.h).padStart(2, '0')}</Text>
                    <Text style={s.timeUnit}>HR</Text>
                  </View>
                  <Text style={[s.timeSep, { color: ringColor }]}>:</Text>
                  <View style={s.digitCard}>
                    <Text style={[s.timeDigit, { color: ringColor }]}>{String(time.m).padStart(2, '0')}</Text>
                    <Text style={s.timeUnit}>MIN</Text>
                  </View>
                  <Text style={[s.timeSep, { color: ringColor }]}>:</Text>
                  <View style={s.digitCard}>
                    <Text style={[s.timeDigit, { color: ringColor }]}>{String(time.s).padStart(2, '0')}</Text>
                    <Text style={s.timeUnit}>SEG</Text>
                  </View>
                </View>

                <Text style={s.subLabel}>
                  {isCompleted ? 'evento terminado' : 'tiempo restante'}
                </Text>

                {isRunning && (
                  <Text style={s.elapsedLabel}>{elapsedTime.full} transcurrido</Text>
                )}
              </View>
            </Animated.View>

            {/* Progress label */}
            <Text style={s.progressText}>{Math.round(progress * 100)}% completado</Text>
          </View>

          {/* ── Break schedule ────────────────────────────────────────── */}
          {schedule.length > 0 && (() => {
            const elapsedMin = elapsed / 60;
            return (
              <View style={s.scheduleCard}>
                <Text style={s.scheduleCardTitle}>Horario del evento</Text>
                <Text style={s.scheduleSubtitle}>
                  {breakType === 'D'
                    ? `${contractHours}h corridas sin descanso`
                    : `Descanso: ${BREAK_LABELS[breakType] ?? breakType}`}
                </Text>
                {schedule.map((seg, i) => {
                  const isActive = elapsedMin >= seg.fromMin && elapsedMin < seg.toMin;
                  const isPast   = elapsedMin >= seg.toMin;
                  return (
                    <View key={i} style={[s.scheduleRow, isActive && s.scheduleRowActive, isPast && s.scheduleRowPast]}>
                      <View style={[
                        s.scheduleIcon,
                        seg.type === 'break' ? s.scheduleIconBreak : s.scheduleIconMusic,
                        isActive && (seg.type === 'break' ? s.scheduleIconBreakActive : s.scheduleIconMusicActive),
                      ]}>
                        {seg.type === 'music'
                          ? <Music2 size={14} color={isActive ? COLORS.bg : isPast ? COLORS.muted : COLORS.green} />
                          : <Coffee size={14} color={isActive ? COLORS.bg : isPast ? COLORS.muted : COLORS.orange} />}
                      </View>
                      <View style={{ flex: 1 }}>
                        <Text style={[s.scheduleLabel, isPast && s.scheduleLabelPast]}>
                          {seg.type === 'music' ? 'Tocando' : 'Descanso'}
                          {isActive && (seg.type === 'music' ? ' 🎵' : ' ☕')}
                        </Text>
                        <Text style={[s.scheduleTime, isPast && s.scheduleTimePast]}>
                          {seg.fromTime} — {seg.toTime}
                        </Text>
                      </View>
                      <Text style={[s.scheduleDuration, isPast && s.scheduleTimePast]}>
                        {seg.toMin - seg.fromMin} min
                      </Text>
                    </View>
                  );
                })}
              </View>
            );
          })()}

          {/* ── Event info ──────────────────────────────────────────── */}
          <View style={s.infoCard}>
            <Text style={s.infoCardTitle}>Detalles del evento</Text>
            {reservation.event_time && (
              <View style={s.infoRow}>
                <Clock size={15} color={COLORS.muted2} />
                <Text style={s.infoText}>Hora: {reservation.event_time}</Text>
              </View>
            )}
            {reservation.address && (
              <View style={s.infoRow}>
                <MapPin size={15} color={COLORS.muted2} />
                <Text style={s.infoText}>{reservation.address}</Text>
              </View>
            )}
            <View style={s.infoRow}>
              <Text style={{ fontSize: 14 }}>🎵</Text>
              <Text style={s.infoText}>
                Evento — {contractHours}h
              </Text>
            </View>
          </View>

          {/* ── Arrived banner ─────────────────────────────────────── */}
          {/* Hora exacta + sello "Verificado por GPS" (petición del usuario
              2026-09-10): antes solo decía "ya llegó" sin más detalle — con
              esto el cliente ve la evidencia dura sin tener que reclamarle
              al admin si duda de su propio recuerdo. arrival_gps_verified es
              false (no null) cuando el evento no tenía coordenadas para
              comparar (sql/424) — en ese caso no se muestra el sello, pero
              la hora de llegada sí, porque esa siempre se registra. */}
          {reservation.group_arrived_at && (
            <View style={s.arrivedBanner}>
              <Text style={s.arrivedIcon}>📍</Text>
              <View style={{ flex: 1 }}>
                <Text style={s.arrivedTitle}>¡El grupo ya llegó!</Text>
                <Text style={s.arrivedSub}>
                  Llegó a las {new Date(reservation.group_arrived_at).toLocaleTimeString('es-MX', { hour: 'numeric', minute: '2-digit' })}
                  {reservation.arrival_gps_verified ? ' · ✅ Verificado por GPS' : ''}
                </Text>
              </View>
            </View>
          )}

          {/* ── Chat ───────────────────────────────────────────────── */}
          {(reservation.group_arrived_at || isRunning) && !isCompleted && (
            <Pressable
              style={s.chatBtn}
              onPress={() => navigation.navigate('Chat', { reservation, senderRole: 'client' })}
            >
              <MessageCircle size={18} color={COLORS.bg} />
              <Text style={s.chatBtnText}>💬 Chat con el grupo</Text>
            </Pressable>
          )}

          {/* ── Completed state ─────────────────────────────────────── */}
          {isCompleted && (
            <View style={s.completedCard}>
              <Text style={s.completedEmoji}>🎉</Text>
              <Text style={s.completedTitle}>¡Evento finalizado!</Text>
              <Text style={s.completedSub}>
                ¡Gracias por confiar en Daricefy! Tu calificación ayuda a mejorar el servicio.
              </Text>

              {!feedbackSent ? (
                <View style={s.feedbackBox}>
                  <Text style={s.feedbackQuestion}>¿Todo salió bien?</Text>
                  {reportingProblem && (
                    <View style={s.issueBox}>
                      <TextInput
                        style={s.issueInput}
                        placeholder="¿Qué ocurrió? Tu reporte ayuda a mejorar el servicio."
                        placeholderTextColor={COLORS.muted}
                        multiline
                        numberOfLines={3}
                        value={issueText}
                        onChangeText={setIssueText}
                      />
                      <View style={s.feedbackRow}>
                        <Pressable
                          style={[s.feedbackBtn, s.feedbackBtnNo]}
                          onPress={() => { setReportingProblem(false); setIssueText(''); }}
                        >
                          <Text style={s.feedbackBtnNoText}>Cancelar</Text>
                        </Pressable>
                        <Pressable
                          style={[s.feedbackBtn, s.feedbackBtnYes]}
                          onPress={async () => {
                            await supabase.rpc('submit_event_feedback', {
                              p_reservation_id: reservation.id,
                              p_had_issue: true,
                              p_issue_text: issueText.trim() || null,
                            });
                            setFeedbackSent(true);
                          }}
                        >
                          <Text style={s.feedbackBtnYesText}>Enviar reporte</Text>
                        </Pressable>
                      </View>
                    </View>
                  )}
                  <View style={s.feedbackRow}>
                    <Pressable
                      style={[s.feedbackBtn, s.feedbackBtnYes]}
                      onPress={async () => {
                        await supabase.rpc('submit_event_feedback', {
                          p_reservation_id: reservation.id,
                          p_had_issue: false,
                        });
                        setFeedbackSent(true);
                      }}
                    >
                      <Text style={s.feedbackBtnYesText}>Sí, todo bien</Text>
                    </Pressable>
                    <Pressable
                      style={[s.feedbackBtn, s.feedbackBtnNo]}
                      onPress={() => setReportingProblem(true)}
                    >
                      <Text style={s.feedbackBtnNoText}>Reportar problema</Text>
                    </Pressable>
                  </View>
                </View>
              ) : (
                <Text style={s.feedbackThanks}>Gracias por tu respuesta 👍</Text>
              )}
            </View>
          )}

        </ScrollView>
      </SafeAreaView>

      {/* Extra hours modal */}
      <ExtraHoursModal
        visible={showExtraModal}
        pricePerHour={pricePerHour}
        awaiting={awaitingGroupConfirm}
        onClose={() => setShowExtraModal(false)}
        onConfirm={async (hours, total) => {
          setAwaitingGroupConfirm(true);
          const { error } = await supabase.rpc('request_extra_hours_client', {
            p_reservation_id: reservation.id,
            p_hours: hours,
            p_total_cost: total,
          });
          if (error) {
            setAwaitingGroupConfirm(false);
            console.error('request_extra_hours_client:', error.message);
          }
        }}
      />

      {/* Aviso legal — accesible desde el evento ya pagado, no solo antes de
          pagar (docs/legal_provider_liability_draft.md, sección 5). */}
      <Modal visible={showLegalNotice} transparent animationType="slide" onRequestClose={() => setShowLegalNotice(false)}>
        <View style={xh.backdrop}>
          <View style={xh.sheet}>
            <View style={{ flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'space-between' }}>
              <Text style={xh.title}>Aviso importante</Text>
              <Pressable onPress={() => setShowLegalNotice(false)} hitSlop={10}>
                <X size={20} color={COLORS.muted2} />
              </Pressable>
            </View>
            <Text style={xh.sub}>
              Daricefy conecta y cotiza, pero el servicio de este evento lo presta{' '}
              <Text style={{ fontFamily: 'DMSans_600SemiBold', color: COLORS.text }}>{groupName}</Text>, un
              proveedor independiente — no un empleado de Daricefy. Daricefy no es responsable por la
              calidad, seguridad o legalidad de lo que el proveedor entregue.{'\n\n'}
              Cualquier reclamo sobre el servicio en sí se resuelve directamente con el proveedor;
              Daricefy ayuda con la evidencia registrada (chat, GPS, pagos) pero no es parte del
              servicio contratado.
            </Text>
            <Pressable style={xh.cancel} onPress={() => setShowLegalNotice(false)}>
              <Text style={xh.cancelText}>Entendido</Text>
            </Pressable>
          </View>
        </View>
      </Modal>
    </View>
  );
}

const s = StyleSheet.create({
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
  scroll: { padding: SPACING.xl, alignItems: 'center', paddingBottom: 40 },

  // Badge
  liveBadgeRow: { marginBottom: 16 },
  liveBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: 'rgba(239,83,80,0.12)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(239,83,80,0.4)',
    paddingHorizontal: 16, paddingVertical: 8,
  },
  liveBadgeBreak: { backgroundColor: 'rgba(255,152,0,0.12)', borderColor: 'rgba(255,152,0,0.4)' },
  liveDot: { width: 10, height: 10, borderRadius: 5, backgroundColor: COLORS.red },
  liveBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.red, letterSpacing: 1 },

  // Group row
  groupRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 20 },
  groupName: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text },

  // Timer SVG
  timerSection: { alignItems: 'center', marginBottom: 24, width: '100%' },
  outerGlow: {
    position: 'absolute', top: -10, width: 340, height: 340, borderRadius: 170,
    borderWidth: 1.5, shadowOffset: { width: 0, height: 0 },
    shadowOpacity: 0.5, shadowRadius: 30, elevation: 0,
  },
  timerSvgWrap: {
    width: 320, height: 320,
    alignItems: 'center', justifyContent: 'center',
    marginBottom: 12,
  },
  timerCenterOverlay: {
    position: 'absolute', alignItems: 'center', justifyContent: 'center',
    width: 200, height: 200,
  },
  segBadge: {
    flexDirection: 'row', alignItems: 'center', gap: 5,
    paddingHorizontal: 10, paddingVertical: 4, borderRadius: 20,
    borderWidth: 1, marginBottom: 8,
  },
  segBadgeText: { fontFamily: FONTS.bodySemiBold, fontSize: 10, letterSpacing: 1.2 },
  stateLabel: { fontFamily: FONTS.body, fontSize: 10, color: COLORS.muted, letterSpacing: 1.5, marginBottom: 8 },
  timeRow: { flexDirection: 'row', alignItems: 'flex-start' },
  digitCard: { alignItems: 'center' },
  timeDigit: { fontFamily: FONTS.title, fontSize: 40, lineHeight: 46 },
  timeUnit: { fontFamily: FONTS.body, fontSize: 9, color: COLORS.muted, letterSpacing: 1, marginTop: -4 },
  timeSep: { fontFamily: FONTS.title, fontSize: 30, lineHeight: 46, marginHorizontal: 2 },
  subLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 4, letterSpacing: 0.5 },
  elapsedLabel: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 6, letterSpacing: 0.3 },
  progressText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 4 },

  // Schedule
  scheduleCard: {
    width: '100%', backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 14,
  },
  scheduleCardTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2, textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 4 },
  scheduleSubtitle: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginBottom: 14 },
  scheduleRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 10, paddingHorizontal: 10, borderRadius: RADIUS.md, marginBottom: 4 },
  scheduleRowActive: { backgroundColor: 'rgba(0,230,118,0.08)', borderWidth: 1, borderColor: 'rgba(0,230,118,0.3)' },
  scheduleRowPast: { opacity: 0.5 },
  scheduleIcon: { width: 30, height: 30, borderRadius: 15, alignItems: 'center', justifyContent: 'center' },
  scheduleIconMusic: { backgroundColor: 'rgba(0,230,118,0.12)' },
  scheduleIconBreak: { backgroundColor: 'rgba(255,152,0,0.12)' },
  scheduleIconMusicActive: { backgroundColor: COLORS.green },
  scheduleIconBreakActive: { backgroundColor: COLORS.orange },
  scheduleLabel: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text },
  scheduleLabelPast: { color: COLORS.muted },
  scheduleTime: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1 },
  scheduleTimePast: { color: COLORS.muted },
  scheduleDuration: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  // Info card
  infoCard: {
    width: '100%', backgroundColor: COLORS.card,
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: COLORS.border,
    padding: SPACING.lg, marginBottom: 14, gap: 10,
  },
  infoCardTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.muted2, textTransform: 'uppercase', letterSpacing: 0.8, marginBottom: 4 },
  infoRow: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  infoText: { fontFamily: FONTS.body, fontSize: 14, color: COLORS.text, flex: 1 },

  // Arrived banner
  arrivedBanner: {
    width: '100%', flexDirection: 'row', alignItems: 'center', gap: 12,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    padding: SPACING.lg, marginBottom: 14,
  },
  arrivedIcon: { fontSize: 24 },
  arrivedTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  arrivedSub: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },

  // Chat
  chatBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8,
    width: '100%', backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 14, marginBottom: 14,
  },
  chatBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },

  // Completed
  completedCard: {
    width: '100%', backgroundColor: 'rgba(0,230,118,0.07)',
    borderRadius: RADIUS.xl, borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    padding: 28, alignItems: 'center', marginBottom: 14,
  },
  completedEmoji: { fontSize: 44, marginBottom: 10 },
  completedTitle: { fontFamily: FONTS.title, fontSize: 22, color: COLORS.text, marginBottom: 8 },
  completedSub: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, textAlign: 'center', lineHeight: 20 },

  // Post-event feedback
  feedbackBox: { width: '100%', marginTop: 16, paddingTop: 16, borderTopWidth: 1, borderTopColor: 'rgba(255,255,255,0.08)' },
  feedbackQuestion: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, textAlign: 'center', marginBottom: 12 },
  feedbackRow: { flexDirection: 'row', gap: 10 },
  feedbackBtn: { flex: 1, borderRadius: RADIUS.lg, paddingVertical: 11, alignItems: 'center', justifyContent: 'center' },
  feedbackBtnYes: { backgroundColor: COLORS.green },
  feedbackBtnYesText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
  feedbackBtnNo: { backgroundColor: 'transparent', borderWidth: 1, borderColor: 'rgba(255,82,82,0.4)' },
  feedbackBtnNoText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: '#FF5252' },
  feedbackThanks: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, marginTop: 12, textAlign: 'center' },
  issueBox: { marginBottom: 12, gap: 10 },
  issueInput: {
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 12, paddingVertical: 10,
    fontFamily: FONTS.body, fontSize: 13, color: COLORS.text,
    textAlignVertical: 'top', minHeight: 72,
  },

  // Over-contract badge
  overContractBadge: {
    backgroundColor: 'rgba(255,82,82,0.12)', borderRadius: RADIUS.full,
    borderWidth: 1, borderColor: 'rgba(255,82,82,0.4)',
    paddingHorizontal: 14, paddingVertical: 5,
  },
  overContractText: { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: '#FF5252', letterSpacing: 0.8 },
});
