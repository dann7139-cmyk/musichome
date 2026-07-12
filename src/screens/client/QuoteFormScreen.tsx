/**
 * QuoteFormScreen — Cliente solicita cotización personalizada a un grupo.
 * Mínimo 3 horas. El cliente elige el tipo de descanso en el formulario.
 */
import React, { useEffect, useMemo, useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ArrowLeft, CheckCircle, Clock, Send } from 'lucide-react-native';
import { Calendar } from 'react-native-calendars';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import TimePickerModal from '../../components/ui/TimePickerModal';
import MapAddressPicker, { AddressResult } from '../../components/ui/MapAddressPicker';
import { analyzeMessage, PHONE_WARNING } from '../../utils/phoneFilter';
import { checkGroupLogistics } from '../../utils/logistics';
import { containsBlockedContact } from '../../utils/contentModeration';
import i18n from '../../i18n';

// ─── Opciones ────────────────────────────────────────────────────────────────

const EVENT_TYPES = [
  { key: 'fiesta_privada', label: '🎉 Fiesta privada' },
  { key: 'boda',           label: '💍 Boda' },
  { key: 'cumpleanos',     label: '🎂 Cumpleaños' },
  { key: 'graduacion',     label: '🎓 Graduación' },
  { key: 'empresarial',    label: '🏢 Empresarial' },
  { key: 'otro',           label: '🎵 Otro' },
];

// Mínimo 3 horas por regla del negocio
const DURATION_OPTIONS = [
  { value: 3,  label: '3 horas' },
  { value: 4,  label: '4 horas' },
  { value: 5,  label: '5 horas' },
  { value: 6,  label: '6 horas' },
  { value: 7,  label: '7 horas' },
  { value: 8,  label: '8+ horas' },
];

const COVERED_OPTIONS = [
  { key: 'si',    label: 'Sí' },
  { key: 'no',    label: 'No' },
  { key: 'no_se', label: 'No sé' },
];

const VENUE_SIZES = [
  { key: 'patio_pequeno',         label: '🏡 Patio pequeño' },
  { key: 'salon_mediano',         label: '🏛️ Salón mediano' },
  { key: 'jardin_grande',         label: '🌳 Jardín grande' },
  { key: 'escenario_profesional', label: '🎤 Escenario profesional' },
];

const SOUND_OPTIONS = [
  { key: 'no_group_brings', label: 'No (grupo trae)' },
  { key: 'si_50',           label: 'Sí, hasta 50' },
  { key: 'si_100',          label: 'Sí, hasta 100' },
  { key: 'si_200',          label: 'Sí, hasta 200' },
  { key: 'si_300',          label: 'Sí, 300+' },
];

const LIGHTING_OPTIONS = [
  { key: 'no',      label: 'No' },
  { key: 'simple',  label: 'Sencilla' },
  { key: 'pro',     label: 'Profesional' },
  { key: 'premium', label: 'Premium' },
];

const STAGE_OPTIONS = [
  { key: 'no',      label: 'No' },
  { key: 'small',   label: 'Chico 3×2m' },
  { key: 'medium',  label: 'Mediano 4×3m' },
  { key: 'wedding', label: 'Grande boda 6×4m' },
];

const LED_OPTIONS = [
  { key: 'no',     label: 'No' },
  { key: 'medium', label: 'Mediana' },
  { key: 'large',  label: 'Grande' },
  { key: 'xl',     label: 'XL boda' },
];

const BREAK_OPTIONS = [
  { type: 'A', label: '15 min por hora',  desc: 'Descanso de 15 min después de cada hora (excepto la última)' },
  { type: 'B', label: '15 min único',     desc: 'Un solo descanso de 15 min a la mitad del evento' },
  { type: 'D', label: 'Sin descanso',     desc: 'El grupo toca corrido sin pausas (solo para eventos de 3h exactas)' },
];

// ─── Helpers ─────────────────────────────────────────────────────────────────

function SectionTitle({ children }: { children: React.ReactNode }) {
  return <Text style={s.sectionTitle}>{children}</Text>;
}

function ChipRow<T extends string | number>({
  options, selected, onSelect,
}: {
  options: { key: T; label: string; disabled?: boolean; warn?: boolean }[];
  selected: T | null;
  onSelect: (v: T) => void;
}) {
  return (
    <View style={s.chipRow}>
      {options.map(o => (
        <Pressable
          key={String(o.key)}
          disabled={o.disabled}
          style={[
            s.chip,
            o.warn && selected !== o.key && s.chipWarn,
            o.disabled && s.chipDisabled,
            selected === o.key && s.chipActive,
          ]}
          onPress={() => onSelect(o.key)}
        >
          <Text style={[
            s.chipText,
            o.warn && selected !== o.key && s.chipTextWarn,
            o.disabled && s.chipTextDisabled,
            selected === o.key && s.chipTextActive,
          ]}>
            {o.label}
          </Text>
        </Pressable>
      ))}
    </View>
  );
}

// ─── Equipment helpers ────────────────────────────────────────────────────────

type InclusionLabel = '✅ Incluido' | '⚠️ Cotización extra';

type GroupEquip = {
  has_sound: boolean;           sound_capacity_max: number | null;
  has_lighting: boolean;        lighting_level: string | null;
  has_stage: boolean;           stage_sizes_available: string[];
  has_led_screen: boolean;      led_sizes_available: string[];
};

const LIGHTING_HIERARCHY: Record<string, number> = {
  simple: 1, pro: 2, premium: 3,
};

function getInclusionLabel(
  category: 'sound' | 'lighting' | 'stage' | 'led',
  value: string,
  equip: GroupEquip | null,
): InclusionLabel | null {
  if (!equip) return null;

  if (category === 'sound') {
    if (value === 'no_group_brings') return '✅ Incluido';
    if (!equip.has_sound) return '⚠️ Cotización extra';
    const capMap: Record<string, number> = { si_50: 50, si_100: 100, si_200: 200, si_300: 300 };
    return (capMap[value] ?? 0) <= (equip.sound_capacity_max ?? 0)
      ? '✅ Incluido' : '⚠️ Cotización extra';
  }
  if (category === 'lighting') {
    if (value === 'no') return null;
    if (!equip.has_lighting) return '⚠️ Cotización extra';
    const clientLevel = LIGHTING_HIERARCHY[value] ?? 0;
    const groupLevel  = LIGHTING_HIERARCHY[equip.lighting_level ?? ''] ?? 0;
    return clientLevel <= groupLevel ? '✅ Incluido' : '⚠️ Cotización extra';
  }
  if (category === 'stage') {
    if (value === 'no') return null;
    if (!equip.has_stage) return '⚠️ Cotización extra';
    return equip.stage_sizes_available.includes(value) ? '✅ Incluido' : '⚠️ Cotización extra';
  }
  if (category === 'led') {
    if (value === 'no') return null;
    if (!equip.has_led_screen) return '⚠️ Cotización extra';
    return equip.led_sizes_available.includes(value) ? '✅ Incluido' : '⚠️ Cotización extra';
  }
  return null;
}

// ─── Screen ──────────────────────────────────────────────────────────────────

export default function QuoteFormScreen({ route, navigation }: any) {
  const { group } = route.params as { group: any };

  // ── Estado del formulario ────────────────────────────────────────────────
  const [eventType,    setEventType]    = useState<string | null>(null);
  const [address,      setAddress]      = useState('');
  const [municipio,    setMunicipio]    = useState('');
  const [estado,       setEstado]       = useState('');
  const [eventDate,    setEventDate]    = useState('');   // 'YYYY-MM-DD'

  // [Lote 2] Días bloqueados/ocupados del grupo — mismo patrón que BookingScreen
  const [unavailMarked, setUnavailMarked] = useState<any>({});
  // Horarios ocupados del grupo por fecha (aviso sin bloquear el día:
  // el grupo puede tocar dos eventos el mismo día en horarios distintos)
  const [busyByDate, setBusyByDate] = useState<Record<string, { time: string | null; hours: number | null }[]>>({});

  useEffect(() => {
    (async () => {
      const today = new Date();
      const inOneYear = new Date(today);
      inOneYear.setFullYear(inOneYear.getFullYear() + 1);
      const ds = (d: Date) =>
        `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
      const [{ data: busy }, { data: blocked }] = await Promise.all([
        supabase.rpc('get_group_busy_days', {
          p_group_id: group.id, p_from: ds(today), p_to: ds(inOneYear),
        }),
        supabase.from('group_unavailability').select('date').eq('group_id', group.id),
      ]);
      const marked: any = {};
      const byDate: Record<string, { time: string | null; hours: number | null }[]> = {};
      // Días CON evento: NARANJA y SELECCIONABLES — el grupo puede tocar dos
      // veces el mismo día; al elegirlo se muestra el horario ocupado.
      (busy ?? []).forEach((r: any) => {
        if (!r.event_date) return;
        (byDate[r.event_date] ??= []).push({ time: r.event_time ?? null, hours: r.hours_count ?? null });
        marked[r.event_date] = {
          customStyles: {
            container: { backgroundColor: 'rgba(255,179,0,0.18)' },
            text: { color: '#FFB300', fontWeight: '700' },
          },
        };
      });
      // Días BLOQUEADOS por el grupo: esos sí quedan deshabilitados.
      (blocked ?? []).forEach((b: any) => {
        if (b.date) {
          marked[b.date] = {
            disabled: true, disableTouchEvent: true,
            customStyles: {
              container: { backgroundColor: COLORS.card2 },
              text: { color: COLORS.muted, textDecorationLine: 'line-through' },
            },
          };
          delete byDate[b.date];
        }
      });
      setUnavailMarked(marked);
      setBusyByDate(byDate);
    })();
  }, [group.id]);
  const [eventTime,    setEventTime]    = useState('');   // 'HH:MM'
  const [duration,     setDuration]     = useState<number | null>(null);
  const [numPersonas,  setNumPersonas]  = useState('');
  const [venueCovered, setVenueCovered] = useState<string | null>(null);
  const [venueSize,    setVenueSize]    = useState<string | null>(null);
  const [needsSound,   setNeedsSound]   = useState<string | null>(null);
  const [comments,     setComments]     = useState('');
  const [commentsWarn, setCommentsWarn] = useState(false);
  // 🎁 Es un regalo (toggle opcional — cualquier reserva, local o de otra ciudad)
  const [isGift,        setIsGift]        = useState(false);
  const [giftRecipient, setGiftRecipient] = useState('');
  const [giftContact,   setGiftContact]   = useState('');
  const [giftMessage,   setGiftMessage]   = useState('');
  const [latitude,     setLatitude]     = useState<number | null>(null);
  const [longitude,    setLongitude]    = useState<number | null>(null);
  const [addressConfirmed, setAddressConfirmed] = useState(false);
  const [loading,      setLoading]      = useState(false);
  const [calendarOpen, setCalendarOpen] = useState(false);
  const [timePickerOpen, setTimePickerOpen] = useState(false);
  const [mapPickerOpen, setMapPickerOpen] = useState(false);
  const [showManualAddress, setShowManualAddress] = useState(false);
  const [breakType,            setBreakType]            = useState<string>('A');
  const [bypassProximityBlock, setBypassProximityBlock] = useState(false);

  // ── Equipo del grupo ─────────────────────────────────────────────────────
  const [groupEquip,     setGroupEquip]     = useState<GroupEquip | null>(null);
  const [lightingNeeded, setLightingNeeded] = useState<string | null>(null);
  const [stageNeeded,    setStageNeeded]    = useState<string | null>(null);
  const [ledNeeded,      setLedNeeded]      = useState<string | null>(null);

  useEffect(() => {
    supabase
      .from('groups')
      .select('has_sound, sound_capacity_max, has_lighting, lighting_level, has_stage, stage_sizes_available, has_led_screen, led_sizes_available')
      .eq('id', group.id)
      .single()
      .then(({ data }) => { if (data) setGroupEquip(data as GroupEquip); });
  }, [group.id]);

  // Reset bypass when the user changes date or time
  useEffect(() => { setBypassProximityBlock(false); }, [eventDate, eventTime]);

  // Horas restantes al evento (null si falta fecha u hora)
  const hoursUntilEvent = useMemo(() => {
    if (!eventDate || !eventTime) return null;
    const dt = new Date(`${eventDate}T${eventTime}:00`);
    return (dt.getTime() - Date.now()) / 3_600_000;
  }, [eventDate, eventTime]);

  // 'past' | 'block' (<6h) | 'warn' (6-24h) | 'ok' (>24h) | null (sin fecha/hora)
  const proximityLevel = useMemo(() => {
    if (hoursUntilEvent === null) return null;
    if (hoursUntilEvent < 0)  return 'past'  as const;
    if (hoursUntilEvent < 6)  return 'block' as const;
    if (hoursUntilEvent < 24) return 'warn'  as const;
    return 'ok' as const;
  }, [hoursUntilEvent]);

  const onConfirmAddress = (result: AddressResult) => {
    setAddress(result.address);
    setMunicipio(result.municipio);
    setEstado(result.estado);
    setLatitude(result.latitude);
    setLongitude(result.longitude);
    setAddressConfirmed(true);
    setMapPickerOpen(false);
    setShowManualAddress(false);
  };

  const formatTime12h = (t: string) => {
    const [hStr, mStr] = t.split(':');
    const h = parseInt(hStr, 10);
    const ampm = h >= 12 ? 'PM' : 'AM';
    const h12 = h % 12 || 12;
    return `${h12}:${mStr} ${ampm}`;
  };

  // ── Validación ───────────────────────────────────────────────────────────
  const canSubmit = () =>
    !!eventType && address.trim() && municipio.trim() && estado.trim() &&
    addressConfirmed &&
    !!eventDate && !!eventTime && !!duration && !!breakType &&
    !!numPersonas && parseInt(numPersonas) > 0 &&
    !!venueCovered && !!venueSize && !!needsSound &&
    proximityLevel !== 'past' &&
    (proximityLevel !== 'block' || bypassProximityBlock);

  // ── Horarios del día: rangos ocupados y encaje con colchón ───────────────
  const rangesFor = (dateStr: string | null | undefined) =>
    (dateStr ? (busyByDate[dateStr] ?? []) : [])
      .filter(b => b.time)
      .map(b => {
        const [hh, mm] = String(b.time).split(':').map(Number);
        const bs = hh + (mm || 0) / 60;
        return { bs, be: bs + Number(b.hours ?? 3) };
      });

  // ¿Cabe un evento de durH horas iniciando en startH?
  // Colchón ASIMÉTRICO: antes de una tocada existente se exigen gapH horas
  // (2 = límite, 3 = cómodo); después de una tocada solo 1h (quitar sonido
  // y trasladarse) — ej. tocada termina 11pm → se puede iniciar 12am.
  const fitsWithGap = (startH: number, durH: number, gapH: number, ranges: { bs: number; be: number }[]) =>
    ranges.every(r => startH + durH + gapH <= r.bs || startH >= r.be + 1);

  // ── Enviar ───────────────────────────────────────────────────────────────
  const handleSubmit = async () => {
    if (!canSubmit()) {
      Alert.alert('Campos incompletos', 'Por favor completa todos los campos requeridos.');
      return;
    }

    if (comments.trim() && containsBlockedContact(comments)) {
      Alert.alert(i18n.t('moderation.title'), i18n.t('moderation.no_contact'));
      return;
    }

    if (isGift && !giftRecipient.trim()) {
      Alert.alert('¿Para quién es el regalo?', 'Escribe el nombre de la persona a quien le regalas el evento.');
      return;
    }

    const { data: { user } } = await supabase.auth.getUser();
    if (!user) { Alert.alert('Error', 'Sesión no encontrada.'); return; }

    const insertPayload = {
      group_id:        group.id,
      client_id:       user.id,
      event_type:      eventType!,
      event_address:   address.trim(),
      event_municipio: municipio.trim(),
      event_estado:    estado.trim(),
      latitude,
      longitude,
      event_date:      eventDate,
      event_time:      eventTime,
      break_type:      breakType,
      duration_hours:  duration!,
      num_personas:    parseInt(numPersonas),
      venue_covered:   venueCovered,
      venue_size:      venueSize,
      needs_sound:     needsSound,
      needs_lighting:  lightingNeeded,
      needs_stage:     stageNeeded,
      needs_led:       ledNeeded,
      comments:        comments.trim() || null,
      is_gift:         isGift,
      ...(isGift ? {
        gift_recipient_name:    giftRecipient.trim() || null,
        gift_recipient_contact: giftContact.trim() || null,
        gift_message:           giftMessage.trim() || null,
      } : {}),
    };

    const sendQuote = async () => {
    const { data: insertData, error } = await supabase.from('quotes').insert(insertPayload).select('id');
    setLoading(false);

    if (error) {
      console.error('🔴 INSERT quote ERROR:', error);
      Alert.alert(
        'Error detallado',
        `Code: ${error.code ?? '—'}\nMessage: ${error.message ?? '—'}\nDetails: ${error.details ?? '—'}\nHint: ${error.hint ?? '—'}`,
      );
    } else {
      // Notificar al grupo
      const { data: groupData } = await supabase
        .from('groups')
        .select('owner_id')
        .eq('id', group.id)
        .single();
      if (groupData?.owner_id) {
        // Notificar al dueño — quote_id permite abrir el carrusel de
        // programadas con esta cotización primero
        await supabase.from('notifications').insert({
          user_id: groupData.owner_id,
          type:    'new_quote_request',
          title:   '📋 Nueva solicitud de cotización',
          body:    `Un cliente solicita cotización para un evento de ${duration}h. Revisa y envía el precio.`,
          data:    { group_id: group.id, quote_id: insertData?.[0]?.id ?? null },
        });

        // Notificar a los integrantes del grupo
        const { data: members } = await supabase
          .from('job_invitations')
          .select('invited_user_id')
          .eq('group_id', group.id)
          .eq('invitation_type', 'membership')
          .eq('status', 'accepted');

        if (members && members.length > 0) {
          await supabase.from('notifications').insert(
            members.map((m: any) => ({
              user_id: m.invited_user_id,
              type:    'new_quote_request',
              title:   '📋 Nueva solicitud de cotización',
              body:    `Tu grupo recibió una solicitud de cotización de ${duration}h. El dueño enviará el precio.`,
              data:    { group_id: group.id },
            }))
          );
        }

        // Notificar a invitados de trabajo aceptados
        const { data: jobInvites } = await supabase
          .from('job_invitations')
          .select('invited_user_id')
          .eq('group_id', group.id)
          .eq('invitation_type', 'job')
          .eq('status', 'accepted');

        if (jobInvites && jobInvites.length > 0) {
          await supabase.from('notifications').insert(
            jobInvites.map((m: any) => ({
              user_id: m.invited_user_id,
              type:    'new_quote_request',
              title:   '📋 Nueva solicitud de cotización',
              body:    `Tu grupo recibió una solicitud de cotización de ${duration}h. El dueño enviará el precio.`,
              data:    { group_id: group.id },
            }))
          );
        }
      }
      // Si esta solicitud cae DESPUÉS de una tocada del grupo ese día, avisar:
      // al grupo (que pregunte por horas extra de su evento actual) y al
      // primer cliente (que decida pronto si querrá horas extra). Best-effort.
      try {
        const ranges = rangesFor(eventDate);
        const h0 = parseInt(eventTime.split(':')[0], 10);
        const hSel = h0 <= 2 ? h0 + 24 : h0;
        if (ranges.some(r => hSel >= r.be)) {
          void supabase.rpc('notify_prior_event_extra_hours', {
            p_group_id:   group.id,
            p_event_date: eventDate,
            p_event_time: eventTime,
          });
        }
      } catch {}

      Alert.alert(
        '✅ Solicitud enviada',
        `Tu solicitud de cotización a "${group.name}" fue enviada. Te notificaremos cuando el grupo responda.`,
        [{ text: 'Entendido', onPress: () => navigation.goBack() }],
      );
    }
    };

    setLoading(true);

    // Validación logística AUTORITATIVA (check-travel-conflict): traslape,
    // colchón de 2h entre tocadas y tiempo de traslado real si hay coords.
    const logistics = await checkGroupLogistics({
      groupId:       group.id,
      eventDate,
      eventTime,
      durationHours: duration ?? 3,
      lat:           latitude ?? undefined,
      lng:           longitude ?? undefined,
    });

    // Hora "muy cercana": solo falta colchón pero queda ≥1h de margen — se
    // permite enviar y el grupo decide si alcanza a llegar.
    const tightButPossible =
      logistics.conflict &&
      logistics.reason === 'time_buffer' &&
      (logistics.gapMinutes ?? 0) >= 60;

    if (logistics.conflict && !tightButPossible) {
      setLoading(false);
      Alert.alert(
        '⏰ Ese horario no le da al grupo',
        logistics.messageClient ??
          'El grupo tiene otra tocada muy cerca de ese horario y no alcanzaría a llegar. Revisa la rejilla de horarios disponibles y elige otra hora.',
      );
      return;
    }

    if (tightButPossible) {
      setLoading(false);
      Alert.alert(
        '🕐 Hora muy cercana a otra tocada',
        'Ese día el grupo tiene otra tocada y el tiempo para trasladarse queda muy justo. Puedes enviar tu solicitud de todos modos: el grupo verá los horarios y decidirá si alcanza a llegar.',
        [
          { text: 'Cambiar hora', style: 'cancel' },
          { text: 'Enviar así', onPress: () => { setLoading(true); void sendQuote(); } },
        ],
      );
      return;
    }

    await sendQuote();
  };

  // ── Render ───────────────────────────────────────────────────────────────
  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <View style={{ flex: 1 }}>
          <Text style={s.headerTitle}>Solicitar cotización</Text>
          <Text style={s.headerSub}>{group.name}</Text>
        </View>
      </SafeAreaView>

      {/* ── Progreso ─────────────────────────────────────────────────────────── */}
      {(() => {
        const sections = [
          !!eventType,
          !!(address.trim() && addressConfirmed),
          !!eventDate,
          !!eventTime,
          !!duration,
          !!breakType,
          !!(numPersonas && parseInt(numPersonas, 10) > 0),
          !!venueCovered,
          !!venueSize,
          !!needsSound,
        ];
        const completed = sections.filter(Boolean).length;
        const total = sections.length;
        return (
          <View style={s.progressWrap}>
            <View style={s.progressTrack}>
              <View style={[s.progressFill, { width: `${Math.round((completed / total) * 100)}%` as any }]} />
            </View>
            <Text style={s.progressLabel}>{completed} de {total} completadas</Text>
          </View>
        );
      })()}

      <KeyboardAvoidingView
        style={{ flex: 1 }}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      >
        <ScrollView
          contentContainerStyle={s.scroll}
          showsVerticalScrollIndicator={false}
          keyboardShouldPersistTaps="handled"
          keyboardDismissMode="on-drag"
        >

          {/* Info banner */}
          <View style={s.infoBanner}>
            <Text style={s.infoBannerText}>
              📍 El grupo revisará tu solicitud y te enviará un precio personalizado. Mínimo 3 horas de servicio.
            </Text>
          </View>

          {/* ─── 1. TIPO DE EVENTO ──────────────────────────────── */}
          <SectionTitle>1. Tipo de evento *</SectionTitle>
          <View style={s.chipGrid}>
            {EVENT_TYPES.map(o => (
              <Pressable
                key={o.key}
                style={[s.chipWide, eventType === o.key && s.chipActive]}
                onPress={() => setEventType(o.key)}
              >
                <Text style={[s.chipText, eventType === o.key && s.chipTextActive]}>
                  {o.label}
                </Text>
              </Pressable>
            ))}
          </View>

          {/* ─── 2. UBICACIÓN ───────────────────────────────────── */}
          <SectionTitle>2. Ubicación del evento *</SectionTitle>

          {address && !showManualAddress ? (
            /* Address confirmed via map */
            <View style={s.addressCard}>
              <CheckCircle size={16} color={COLORS.green} style={{ marginTop: 2, flexShrink: 0 }} />
              <View style={{ flex: 1 }}>
                <Text style={s.addressCardText} numberOfLines={2}>{address}</Text>
                {(municipio || estado) ? (
                  <Text style={s.addressCardSub}>{[municipio, estado].filter(Boolean).join(', ')}</Text>
                ) : null}
              </View>
              <Pressable onPress={() => setMapPickerOpen(true)}>
                <Text style={s.addressCardEdit}>Cambiar</Text>
              </Pressable>
            </View>
          ) : showManualAddress ? (
            /* Manual input fallback */
            <>
              <TextInput
                style={s.input}
                placeholder="Dirección completa"
                placeholderTextColor={COLORS.muted}
                value={address}
                onChangeText={t => { setAddress(t); setAddressConfirmed(false); }}
              />
              <View style={s.row2}>
                <TextInput
                  style={[s.input, { flex: 1 }]}
                  placeholder="Municipio"
                  placeholderTextColor={COLORS.muted}
                  value={municipio}
                  onChangeText={t => { setMunicipio(t); setAddressConfirmed(false); }}
                />
                <TextInput
                  style={[s.input, { flex: 1 }]}
                  placeholder="Estado"
                  placeholderTextColor={COLORS.muted}
                  value={estado}
                  onChangeText={t => { setEstado(t); setAddressConfirmed(false); }}
                />
              </View>
              <Pressable onPress={() => setMapPickerOpen(true)} style={s.useMapBtn}>
                <Text style={s.useMapBtnText}>📍 Usar mapa</Text>
              </Pressable>
            </>
          ) : (
            /* Default: open map picker */
            <>
              <Pressable style={s.mapPickerBtn} onPress={() => setMapPickerOpen(true)}>
                <Text style={s.mapPickerBtnText}>📍 Seleccionar en el mapa</Text>
              </Pressable>
              <Pressable onPress={() => setShowManualAddress(true)} style={s.manualFallback}>
                <Text style={s.manualFallbackText}>Escribir dirección manualmente</Text>
              </Pressable>
            </>
          )}

          {/* ─── 3. FECHA ────────────────────────────────────────── */}
          <SectionTitle>3. Fecha del evento *</SectionTitle>
          <Pressable style={s.dateBtn} onPress={() => setCalendarOpen(true)}>
            <Text style={[s.dateBtnText, !eventDate && { color: COLORS.muted }]}>
              {eventDate
                ? new Date(eventDate + 'T12:00:00').toLocaleDateString('es-MX', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })
                : '📅 Seleccionar fecha'}
            </Text>
          </Pressable>

          {/* Aviso: el grupo ya tiene evento ese día (se puede contratar en otro horario) */}
          {eventDate && busyByDate[eventDate]?.length ? (
            <View style={s.busyNotice}>
              <Text style={s.busyNoticeTitle}>🎪 El grupo ya tiene evento este día:</Text>
              {busyByDate[eventDate].map((ev, i) => {
                const fmt12 = (t: string) => {
                  const [h, m] = t.split(':').map(Number);
                  return `${h % 12 || 12}:${String(m).padStart(2, '0')} ${h >= 12 ? 'PM' : 'AM'}`;
                };
                const start = ev.time ? fmt12(ev.time) : null;
                const end = ev.time && ev.hours
                  ? fmt12(`${(parseInt(ev.time.split(':')[0], 10) + Math.round(Number(ev.hours))) % 24}:${ev.time.split(':')[1]}`)
                  : null;
                return (
                  <Text key={i} style={s.busyNoticeLine}>
                    · {start ? `De ${start}${end ? ` a ${end}` : ''}` : 'Horario por confirmar'}
                  </Text>
                );
              })}
              <Text style={s.busyNoticeHint}>
                Puedes contratarlo en un horario diferente — elige tu hora considerando este compromiso.
              </Text>
            </View>
          ) : null}

          {/* ─── 4. HORA ─────────────────────────────────────────── */}
          <SectionTitle>4. Hora de inicio *</SectionTitle>

          {/* Día con evento del grupo: rejilla de horas disponibles vs
              ocupadas (tocada + 2h de colchón para desconectar y trasladarse) */}
          {eventDate && (busyByDate[eventDate]?.length ?? 0) > 0 && (() => {
            const dur = duration ?? 3;
            const ranges = rangesFor(eventDate);
            const fmtH = (h: number) => { const hh = h % 24; return `${hh % 12 || 12}${hh >= 12 ? 'pm' : 'am'}`; };
            const slots: { h: number; status: 'free' | 'tight' | 'buffer' | 'busy' }[] = [];
            // h=24/25/26 = 12am/1am/2am (madrugada de esa noche) — tocadas nocturnas
            for (let h = 9; h <= 26; h++) {
              // La hora en que TERMINA la tocada también se pinta roja (h <= be)
              const insideBusy = ranges.some(r => h >= r.bs && h <= r.be);
              // Antes de otra tocada: 2h obligatorias ("muy cercana" = justo en
              // el límite). Después de una tocada: 1h de quitar sonido y traslado.
              const status = insideBusy ? 'busy'
                : fitsWithGap(h, dur, 3, ranges) ? 'free'
                : fitsWithGap(h, dur, 2, ranges) ? 'tight'
                : 'buffer';
              slots.push({ h, status });
            }
            // Sugerencias: primeras horas libres + la primera libre DESPUÉS de
            // la última tocada (por si el cliente quiere más noche). No se
            // sugiere más allá de la 1am — acabarían de madrugada.
            const lastEnd = Math.max(...ranges.map(r => r.be), 0);
            const nightH = slots.find(sl => sl.status === 'free' && sl.h >= lastEnd && sl.h <= 25)?.h;
            const firstFree = [...new Set([
              ...slots.filter(sl => sl.status === 'free' && sl.h <= 25).slice(0, 2).map(sl => sl.h),
              ...(nightH != null ? [nightH] : []),
            ])].sort((a, b) => a - b);
            const selH0 = eventTime ? parseInt(eventTime.split(':')[0], 10) : null;
            // 00/01/02 guardadas = madrugada de esa noche (celdas 24/25/26)
            const selH = selH0 != null && selH0 <= 2 ? selH0 + 24 : selH0;
            const selSlot = selH == null ? undefined : slots.find(sl => sl.h === selH);
            // ¿La hora elegida es DESPUÉS de una tocada del grupo?
            const afterPriorGig = selH != null && ranges.some(r => selH >= r.be);
            return (
              <View style={s.hourGridCard}>
                <Text style={s.hourGridTitle}>Horarios de tu grupo ese día ({dur}h de evento)</Text>
                <View style={s.hourGrid}>
                  {slots.map(sl => {
                    const disabled = sl.status === 'busy' || sl.status === 'buffer';
                    const suggested = firstFree.includes(sl.h);
                    const selected = selH === sl.h;
                    return (
                      <Pressable
                        key={sl.h}
                        disabled={disabled}
                        onPress={() => {
                          setEventTime(`${String(sl.h % 24).padStart(2, '0')}:00`);
                          // Si la duración elegida ya no cabe con esta hora, se re-elige
                          if (duration && !fitsWithGap(sl.h, duration, 2, ranges)) setDuration(null);
                        }}
                        style={[
                          s.hourCell,
                          sl.status === 'busy'   && s.hourCellBusy,
                          sl.status === 'buffer' && s.hourCellBuffer,
                          sl.status === 'tight'  && s.hourCellTight,
                          suggested && !selected && s.hourCellSuggested,
                          selected && s.hourCellSelected,
                        ]}
                      >
                        <Text style={[
                          s.hourCellTx,
                          disabled && s.hourCellTxDisabled,
                          sl.status === 'tight' && !selected && s.hourCellTxTight,
                          selected && s.hourCellTxSelected,
                        ]}>{fmtH(sl.h)}</Text>
                      </Pressable>
                    );
                  })}
                </View>
                <View style={s.hourLegend}>
                  <Text style={s.hourLegendItem}>🟩 disponible</Text>
                  <Text style={s.hourLegendItem}>🟨 muy cercana</Text>
                  <Text style={s.hourLegendItem}>🟥 tocando</Text>
                  <Text style={s.hourLegendItem}>⬜ traslado</Text>
                </View>
                {selSlot?.status === 'tight' ? (
                  <Text style={s.hourTightTx}>
                    🕐 Hora muy cercana a la otra tocada del grupo — el tiempo le queda justo. El grupo decidirá si la acepta al cotizarte.
                  </Text>
                ) : afterPriorGig && selSlot ? (
                  <Text style={s.hourSuggestTx}>
                    ℹ️ El grupo tiene un evento antes de tu horario. Verá si ese evento pide horas extra y te confirma al cotizarte.
                  </Text>
                ) : firstFree.length > 0 && !eventTime ? (
                  <Text style={s.hourSuggestTx}>
                    💡 Te sugerimos las {firstFree.map(fmtH).join(', ')} — le dan tiempo al grupo entre tocadas
                  </Text>
                ) : null}
              </View>
            );
          })()}

          <Pressable
            style={[s.timeChip, !!eventTime && s.timeChipActive]}
            onPress={() => setTimePickerOpen(true)}
          >
            <Clock size={16} color={eventTime ? COLORS.green : COLORS.muted2} />
            <Text style={[s.timeChipText, !!eventTime && s.timeChipTextActive]}>
              {eventTime ? formatTime12h(eventTime) : 'Toca para elegir la hora'}
            </Text>
          </Pressable>

          {/* ─── BANNER PROXIMIDAD — se muestra en tiempo real ──── */}
          {proximityLevel === 'ok' && (
            <View style={s.proximityOk}>
              <Text style={s.proximityOkText}>✓ El grupo tiene tiempo para coordinarse</Text>
            </View>
          )}
          {proximityLevel === 'warn' && (
            <View style={s.proximityWarn}>
              <Text style={s.proximityWarnText}>
                ⏱ Evento próximo — el grupo tendrá ventana reducida para responder.
              </Text>
            </View>
          )}
          {proximityLevel === 'block' && !bypassProximityBlock && (
            <View style={s.proximityBlock}>
              <Text style={s.proximityBlockTitle}>🚨 Tu evento es en menos de 6 horas</Text>
              <Text style={s.proximityBlockBody}>
                {'Las cotizaciones programadas no son rápidas — el grupo puede tardar en responder y no llegar a tiempo.\n\nPara eventos urgentes usa '}
                <Text style={{ fontFamily: 'DMSans_600SemiBold' }}>Solicitar grupo ahora</Text>
                {' — múltiples grupos disponibles te responderán al instante.'}
              </Text>
              <Pressable
                style={s.proximityExpressBtn}
                onPress={() => navigation.navigate('OpenRequest' as any)}
              >
                <Text style={s.proximityExpressBtnText}>Solicitar grupo ahora →</Text>
              </Pressable>
              <Pressable
                style={s.proximityBypassLink}
                onPress={() => {
                  Alert.alert(
                    'Continuar con cotización programada',
                    'El grupo podría no tener tiempo suficiente para organizarse y llegar al evento. ¿Seguro que quieres enviar la solicitud?',
                    [
                      { text: 'Cancelar', style: 'cancel' },
                      {
                        text: 'Sí, enviar de todas formas',
                        style: 'destructive',
                        onPress: () => setBypassProximityBlock(true),
                      },
                    ],
                  );
                }}
              >
                <Text style={s.proximityBypassLinkText}>Entiendo, continuar de todas formas</Text>
              </Pressable>
            </View>
          )}
          {proximityLevel === 'past' && (
            <View style={s.proximityPast}>
              <Text style={s.proximityPastText}>
                Este evento ya pasó. Selecciona una fecha y hora futura.
              </Text>
            </View>
          )}

          {/* ─── 5. DURACIÓN ─────────────────────────────────────── */}
          <SectionTitle>5. Duración *  <Text style={s.minNote}>(mínimo 3 horas)</Text></SectionTitle>
          {(() => {
            // Día con otra tocada: solo las horas que dejan las 2h de traslado
            // (tocada 8pm → 3pm caben 3h, 2pm caben 4h, 1pm caben 5h). La
            // duración máxima (termina justo 2h antes) va en ámbar: el grupo
            // decidirá si la acepta.
            const ranges = rangesFor(eventDate);
            const selH0 = eventTime ? parseInt(eventTime.split(':')[0], 10) : null;
            // 12am/1am/2am = madrugada de esa noche
            const selH = selH0 != null && selH0 <= 2 ? selH0 + 24 : selH0;
            const constrained = ranges.length > 0 && selH != null;
            const anyBlocked = constrained &&
              DURATION_OPTIONS.some(d => !fitsWithGap(selH!, d.value, 2, ranges));
            return (
              <>
                <ChipRow
                  options={DURATION_OPTIONS.map(d => ({
                    key: d.value, label: d.label,
                    ...(constrained ? {
                      disabled: !fitsWithGap(selH!, d.value, 2, ranges),
                      warn:     fitsWithGap(selH!, d.value, 2, ranges) &&
                                !fitsWithGap(selH!, d.value, 3, ranges),
                    } : {}),
                  }))}
                  selected={duration}
                  onSelect={v => setDuration(Number(v))}
                />
                {anyBlocked && (
                  <Text style={s.durLockTx}>
                    🔒 Ese día tu grupo tiene otra tocada — solo puedes contratar las horas que le dan tiempo de llegar. Elige más temprano para contratar más horas.
                  </Text>
                )}
              </>
            );
          })()}

          {(() => {
            // Si después de este evento el grupo tiene otra tocada ese día, NO
            // habrá horas extra (el traslado es obligatorio) — avisar en vez de
            // sugerir que "puede extender".
            const ranges = rangesFor(eventDate);
            const selH0 = eventTime ? parseInt(eventTime.split(':')[0], 10) : null;
            const selH = selH0 != null && selH0 <= 2 ? selH0 + 24 : selH0;
            const boxedIn = selH != null && ranges.some(r => r.bs > selH + 0.01);
            return (
              <View style={s.extraHoursHint}>
                <Text style={s.extraHoursHintText}>
                  {boxedIn
                    ? 'ℹ️ Después de tu evento el grupo tiene otra tocada, así que NO habrá horas extra ese día. Contrata desde ahora todas las horas que necesitas.'
                    : '💡 Elige bien las horas desde ahora. Si el evento se extiende, cada hora extra se cobra por separado y puede salir más caro que contratarlas de antemano.'}
                </Text>
              </View>
            );
          })()}

          {/* ─── 6. TIPO DE DESCANSO — oculto: el grupo elige en EventTimerScreen */}
          {false && (<>
          <SectionTitle>6. Tipo de descanso *</SectionTitle>
          <Text style={[s.minNote, { marginTop: -8, marginBottom: 12 }]}>
            Todos los tipos están incluidos sin costo adicional.
          </Text>
          <View style={s.breakOptions}>
            {BREAK_OPTIONS.map(opt => (
              <Pressable
                key={opt.type}
                style={[s.breakOpt, breakType === opt.type && s.breakOptActive]}
                onPress={() => setBreakType(opt.type)}
              >
                <Text style={[s.breakOptLabel, breakType === opt.type && { color: COLORS.green }]}>
                  {opt.label}
                </Text>
                <Text style={s.breakOptDesc}>{opt.desc}</Text>
              </Pressable>
            ))}
          </View>
          </>)}

          {/* ─── 7. NÚMERO DE PERSONAS ───────────────────────────── */}
          <SectionTitle>7. Número aproximado de personas *</SectionTitle>
          <TextInput
            style={s.input}
            placeholder="Ej: 50"
            placeholderTextColor={COLORS.muted}
            value={numPersonas}
            onChangeText={t => setNumPersonas(t.replace(/[^0-9]/g, ''))}
            keyboardType="numeric"
            maxLength={4}
          />

          {/* ─── 8. ¿TECHADO? ────────────────────────────────────── */}
          <SectionTitle>8. ¿El lugar está techado? *</SectionTitle>
          <ChipRow
            options={COVERED_OPTIONS as any}
            selected={venueCovered}
            onSelect={setVenueCovered}
          />

          {/* ─── 9. ESPACIO ──────────────────────────────────────── */}
          <SectionTitle>9. Espacio aproximado *</SectionTitle>
          <View style={s.chipGrid}>
            {VENUE_SIZES.map(o => (
              <Pressable
                key={o.key}
                style={[s.chipWide, venueSize === o.key && s.chipActive]}
                onPress={() => setVenueSize(o.key)}
              >
                <Text style={[s.chipText, venueSize === o.key && s.chipTextActive]}>
                  {o.label}
                </Text>
              </Pressable>
            ))}
          </View>

          {/* ─── 10. EQUIPO ──────────────────────────────────────── */}
          <SectionTitle>10. ¿Qué necesitas para tu evento? *</SectionTitle>

          {/* Sonido */}
          <Text style={s.equipSubTitle}>🎵 Sonido *</Text>
          <View style={s.chipRow}>
            {SOUND_OPTIONS.map(o => {
              const lbl = getInclusionLabel('sound', o.key, groupEquip);
              return (
                <View key={o.key} style={s.equipOptCol}>
                  <Pressable
                    style={[s.chip, needsSound === o.key && s.chipActive]}
                    onPress={() => setNeedsSound(o.key)}
                  >
                    <Text style={[s.chipText, needsSound === o.key && s.chipTextActive]}>
                      {o.label}
                    </Text>
                  </Pressable>
                  {lbl && (
                    <Text style={lbl === '✅ Incluido' ? s.inclusionGreen : s.inclusionOrange}>
                      {lbl}
                    </Text>
                  )}
                </View>
              );
            })}
          </View>

          {/* Iluminación */}
          <Text style={s.equipSubTitle}>💡 Iluminación <Text style={s.optionalTag}>(opcional)</Text></Text>
          <View style={s.chipRow}>
            {LIGHTING_OPTIONS.map(o => {
              const lbl = getInclusionLabel('lighting', o.key, groupEquip);
              return (
                <View key={o.key} style={s.equipOptCol}>
                  <Pressable
                    style={[s.chip, lightingNeeded === o.key && s.chipActive]}
                    onPress={() => setLightingNeeded(o.key)}
                  >
                    <Text style={[s.chipText, lightingNeeded === o.key && s.chipTextActive]}>
                      {o.label}
                    </Text>
                  </Pressable>
                  {lbl && (
                    <Text style={lbl === '✅ Incluido' ? s.inclusionGreen : s.inclusionOrange}>
                      {lbl}
                    </Text>
                  )}
                </View>
              );
            })}
          </View>

          {/* Tarima */}
          <Text style={s.equipSubTitle}>🎭 Tarima / Escenario <Text style={s.optionalTag}>(opcional)</Text></Text>
          <View style={s.chipRow}>
            {STAGE_OPTIONS.map(o => {
              const lbl = getInclusionLabel('stage', o.key, groupEquip);
              return (
                <View key={o.key} style={s.equipOptCol}>
                  <Pressable
                    style={[s.chip, stageNeeded === o.key && s.chipActive]}
                    onPress={() => setStageNeeded(o.key)}
                  >
                    <Text style={[s.chipText, stageNeeded === o.key && s.chipTextActive]}>
                      {o.label}
                    </Text>
                  </Pressable>
                  {lbl && (
                    <Text style={lbl === '✅ Incluido' ? s.inclusionGreen : s.inclusionOrange}>
                      {lbl}
                    </Text>
                  )}
                </View>
              );
            })}
          </View>

          {/* LED */}
          <Text style={s.equipSubTitle}>📺 Pantalla LED <Text style={s.optionalTag}>(opcional)</Text></Text>
          <View style={s.chipRow}>
            {LED_OPTIONS.map(o => {
              const lbl = getInclusionLabel('led', o.key, groupEquip);
              return (
                <View key={o.key} style={s.equipOptCol}>
                  <Pressable
                    style={[s.chip, ledNeeded === o.key && s.chipActive]}
                    onPress={() => setLedNeeded(o.key)}
                  >
                    <Text style={[s.chipText, ledNeeded === o.key && s.chipTextActive]}>
                      {o.label}
                    </Text>
                  </Pressable>
                  {lbl && (
                    <Text style={lbl === '✅ Incluido' ? s.inclusionGreen : s.inclusionOrange}>
                      {lbl}
                    </Text>
                  )}
                </View>
              );
            })}
          </View>

          {/* Nota resumen */}
          <View style={s.equipSummaryBox}>
            <Text style={s.equipSummaryText}>
              📋 El grupo verá tu solicitud y enviará el precio total,{'\n'}
              incluyendo cualquier equipo adicional que necesites rentar.
            </Text>
          </View>

          {/* ─── 11. COMENTARIOS ──────────────────────────────────── */}
          <SectionTitle>11. Comentarios adicionales</SectionTitle>
          <TextInput
            style={[s.input, s.inputMulti]}
            placeholder={'Ej: "El evento es en rancho a 30 min de la ciudad"\n"Es al aire libre"\n"Queremos música variada"'}
            placeholderTextColor={COLORS.muted}
            value={comments}
            onChangeText={v => {
              let c = v.replace(/[0-9]/g, '');
              const NUM_WORDS = /\b(cero|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve)([\s\-./]+(cero|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve)){2,}/gi;
              c = c.replace(NUM_WORDS, '');
              const result = analyzeMessage(c);
              setCommentsWarn(result.blocked);
              setComments(c);
            }}
            multiline
            maxLength={500}
            textAlignVertical="top"
          />
          <Text style={s.charCount}>{comments.length}/500</Text>
          {commentsWarn && (
            <View style={s.warnBox}>
              <Text style={s.warnText}>⚠️ {PHONE_WARNING}</Text>
            </View>
          )}

          {/* ─── 🎁 ¿ES UN REGALO? (switch opcional) ──────────────── */}
          <View style={s.giftToggleRow}>
            <View style={{ flex: 1 }}>
              <Text style={s.giftToggleTitle}>🎁 ¿Es un regalo?</Text>
              <Text style={s.giftToggleHint}>Actívalo para regalar este evento a otra persona.</Text>
            </View>
            <Switch
              value={isGift}
              onValueChange={setIsGift}
              trackColor={{ false: '#2A2A2A', true: 'rgba(0,230,118,0.45)' }}
              thumbColor={isGift ? COLORS.green : '#8A8A8A'}
            />
          </View>
          {isGift && (
            <View style={s.giftBox}>
              <Text style={s.giftBoxHint}>
                Al pagar generamos un ticket de regalo para que se lo compartas a quien tú quieras (WhatsApp, correo, etc.), cuando tú decidas.
              </Text>

              <Text style={s.giftLabel}>Para (nombre del festejado) *</Text>
              <TextInput
                style={s.input}
                placeholder="Ej: Mamá, Sofía, Familia López"
                placeholderTextColor={COLORS.muted}
                value={giftRecipient}
                onChangeText={setGiftRecipient}
                maxLength={60}
              />

              <Text style={s.giftLabel}>Mensaje personalizado</Text>
              <TextInput
                style={[s.input, s.inputMulti]}
                placeholder={'Ej: "¡Feliz cumpleaños! Con todo mi cariño 🎉"'}
                placeholderTextColor={COLORS.muted}
                value={giftMessage}
                onChangeText={setGiftMessage}
                multiline
                maxLength={200}
                textAlignVertical="top"
              />

              <Text style={s.giftLabel}>Contacto del destinatario (opcional)</Text>
              <TextInput
                style={s.input}
                placeholder="WhatsApp o correo (opcional)"
                placeholderTextColor={COLORS.muted}
                value={giftContact}
                onChangeText={setGiftContact}
                maxLength={60}
              />
            </View>
          )}

          {/* ─── BOTÓN ENVIAR ────────────────────────────────────── */}
          <Pressable
            style={[s.submitBtn, (!canSubmit() || loading) && s.submitBtnDisabled]}
            onPress={handleSubmit}
            disabled={!canSubmit() || loading}
          >
            <Send size={18} color={canSubmit() ? COLORS.bg : COLORS.muted} />
            <Text style={[s.submitBtnText, !canSubmit() && { color: COLORS.muted }]}>
              {loading ? 'Enviando...' : 'Enviar solicitud de cotización'}
            </Text>
          </Pressable>

          <View style={{ height: 40 }} />
        </ScrollView>
      </KeyboardAvoidingView>

      {/* ── Modal Calendario ─────────────────────────────────────────────────── */}
      <Modal visible={calendarOpen} transparent animationType="slide">
        <View style={s.calOverlay}>
          <View style={s.calSheet}>
            <Text style={s.calTitle}>Selecciona la fecha</Text>
            <Calendar
              onDayPress={(day: any) => {
                if (unavailMarked[day.dateString]?.disabled) {
                  Alert.alert('Fecha no disponible', 'El grupo no está disponible ese día. Elige otra fecha.');
                  return;
                }
                setEventDate(day.dateString);
                setCalendarOpen(false);
              }}
              markedDates={{
                ...unavailMarked,
                ...(eventDate ? { [eventDate]: { selected: true, selectedColor: COLORS.green } } : {}),
              }}
              minDate={(() => { const d = new Date(); d.setDate(d.getDate() - 1); return d.toISOString().split('T')[0]; })()}
              theme={{
                backgroundColor: COLORS.card,
                calendarBackground: COLORS.card,
                textSectionTitleColor: COLORS.muted2,
                selectedDayBackgroundColor: COLORS.green,
                selectedDayTextColor: COLORS.bg,
                todayTextColor: COLORS.green,
                dayTextColor: COLORS.text,
                textDisabledColor: COLORS.muted,
                arrowColor: COLORS.green,
                monthTextColor: COLORS.text,
              }}
            />
            <Pressable style={s.calClose} onPress={() => setCalendarOpen(false)}>
              <Text style={s.calCloseText}>Cancelar</Text>
            </Pressable>
          </View>
        </View>
      </Modal>
      <TimePickerModal
        visible={timePickerOpen}
        value={eventTime}
        title="Hora de inicio"
        onConfirm={(t) => { setEventTime(t); setTimePickerOpen(false); }}
        onClose={() => setTimePickerOpen(false)}
      />

      <MapAddressPicker
        visible={mapPickerOpen}
        onConfirm={onConfirmAddress}
        onClose={() => setMapPickerOpen(false)}
        initialLatitude={latitude ?? undefined}
        initialLongitude={longitude ?? undefined}
      />
    </View>
  );
}

// ─── Styles ──────────────────────────────────────────────────────────────────

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },

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

  scroll: { padding: SPACING.xl, paddingBottom: 160 },

  infoBanner: {
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.25)',
    borderRadius: RADIUS.lg, padding: 14, marginBottom: 24,
  },
  infoBannerText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.green, lineHeight: 20 },

  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text,
    marginTop: 24, marginBottom: 12,
  },
  minNote: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, fontWeight: 'normal' },

  // ── Inputs ────────────────────────────────────────────────────────────────
  input: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 13,
    fontFamily: FONTS.body, fontSize: 14, color: COLORS.text,
    marginBottom: 10,
  },
  inputMulti: { minHeight: 100, paddingTop: 13 },
  charCount:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, textAlign: 'right', marginTop: 2, marginBottom: 10 },
  row2:       { flexDirection: 'row', gap: 10 },

  // ── 🎁 Caja de regalo ──────────────────────────────────────────────────────
  giftToggleRow: {
    flexDirection: 'row', alignItems: 'center', gap: 12,
    marginTop: 12, backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border, padding: SPACING.lg,
  },
  giftToggleTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.text },
  giftToggleHint:  { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2, marginTop: 2 },
  giftBox: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1.5, borderColor: COLORS.green,
    padding: SPACING.lg, marginTop: 8, marginBottom: 4,
  },
  giftBoxTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.green, marginBottom: 4 },
  giftBoxHint:  { fontFamily: FONTS.body, fontSize: 12.5, color: COLORS.muted2, lineHeight: 18, marginBottom: 6 },
  giftLabel:    { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.text, marginTop: 10, marginBottom: 6 },

  // ── Map confirm ───────────────────────────────────────────────────────────
  mapConfirmSection: { marginBottom: 10, marginTop: -4 },
  mapConfirmBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 11, paddingHorizontal: 14,
  },
  mapConfirmBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green, flex: 1 },
  mapConfirmed: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 11, paddingHorizontal: 14,
  },
  mapConfirmedText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.green },
  mapConfirmedLink: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.green, opacity: 0.7, marginTop: 2 },
  mapHint: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 6, marginLeft: 4 },

  // ── Time chip ─────────────────────────────────────────────────────────────
  timeChip: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 15, marginBottom: 10,
  },
  timeChipActive:     { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)' },
  timeChipText:       { fontFamily: FONTS.body, fontSize: 15, color: COLORS.muted2, flex: 1 },
  timeChipTextActive: { fontFamily: FONTS.bodySemiBold, color: COLORS.green },

  // ── Date btn ──────────────────────────────────────────────────────────────
  dateBtn: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 14,
    marginBottom: 10,
  },
  // Aviso de día con evento existente (contratable en otro horario)
  busyNotice: {
    backgroundColor: 'rgba(255,179,0,0.10)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.4)',
    paddingHorizontal: 13, paddingVertical: 11, marginBottom: 10, gap: 3,
  },
  busyNoticeTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#FFB300' },
  busyNoticeLine:  { fontFamily: FONTS.bodyMedium, fontSize: 12.5, color: COLORS.text },
  busyNoticeHint:  { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, marginTop: 3, lineHeight: 15 },

  // ── Rejilla de horas (día con evento del grupo) ──
  hourGridCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 12, marginBottom: 10,
  },
  hourGridTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 12.5, color: COLORS.text, marginBottom: 9 },
  hourGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  hourCell: {
    width: '18%', paddingVertical: 8, borderRadius: RADIUS.sm,
    backgroundColor: 'rgba(0,230,118,0.10)',
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    alignItems: 'center',
  },
  hourCellBusy:      { backgroundColor: 'rgba(239,83,80,0.15)', borderColor: 'rgba(239,83,80,0.45)' },
  hourCellBuffer:    { backgroundColor: 'rgba(255,255,255,0.05)', borderColor: 'rgba(255,255,255,0.12)' },
  hourCellTight:     { backgroundColor: 'rgba(255,193,7,0.10)', borderColor: 'rgba(255,193,7,0.55)' },
  hourCellSuggested: { borderColor: COLORS.green, borderWidth: 1.5 },
  hourCellSelected:  { backgroundColor: COLORS.green, borderColor: COLORS.green },
  hourCellTx:         { fontFamily: FONTS.bodySemiBold, fontSize: 12, color: COLORS.green },
  hourCellTxDisabled: { color: COLORS.muted },
  hourCellTxSelected: { color: '#000' },
  hourLegend: { flexDirection: 'row', gap: 12, marginTop: 9, flexWrap: 'wrap' },
  hourLegendItem: { fontFamily: FONTS.body, fontSize: 10.5, color: COLORS.muted2 },
  hourSuggestTx: { fontFamily: FONTS.bodyMedium, fontSize: 11.5, color: COLORS.green, marginTop: 7, lineHeight: 15 },
  hourCellTxTight: { color: '#FFC107' },
  hourTightTx:   { fontFamily: FONTS.bodyMedium, fontSize: 11.5, color: '#FFC107', marginTop: 7, lineHeight: 15 },
  durLockTx:     { fontFamily: FONTS.body, fontSize: 11.5, color: COLORS.muted2, marginTop: 8, lineHeight: 15 },
  dateBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },

  // ── Chips ─────────────────────────────────────────────────────────────────
  chipRow:  { flexDirection: 'row', gap: 8, flexWrap: 'wrap', marginBottom: 4 },
  chipGrid: { flexDirection: 'row', gap: 10, flexWrap: 'wrap', marginBottom: 4 },
  chip: {
    paddingHorizontal: 14, paddingVertical: 10,
    borderRadius: RADIUS.full,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  chipWide: {
    paddingHorizontal: 14, paddingVertical: 10,
    borderRadius: RADIUS.lg,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
  },
  chipActive:       { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: COLORS.green },
  chipWarn:         { borderColor: 'rgba(255,193,7,0.55)', backgroundColor: 'rgba(255,193,7,0.08)' },
  chipDisabled:     { opacity: 0.3 },
  chipText:         { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  chipTextWarn:     { color: '#FFC107' },
  chipTextDisabled: { textDecorationLine: 'line-through' },
  chipTextActive:   { color: COLORS.green },

  // ── Progreso ──────────────────────────────────────────────────────────────
  progressWrap:  { paddingHorizontal: SPACING.xl, paddingTop: 10, paddingBottom: 6 },
  progressTrack: { width: '100%', height: 4, backgroundColor: COLORS.border, borderRadius: 2, marginBottom: 6 },
  progressFill:  { height: 4, backgroundColor: COLORS.green, borderRadius: 2 },
  progressLabel: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, textAlign: 'right' },

  // ── Submit ────────────────────────────────────────────────────────────────
  submitBtn: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 10,
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 16, marginTop: 28,
  },
  submitBtnDisabled: { opacity: 0.4 },
  submitBtnText:     { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: COLORS.bg },

  // ── Calendar modal ────────────────────────────────────────────────────────
  calOverlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.7)', justifyContent: 'flex-end' },
  calSheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: 24, borderTopRightRadius: 24,
    paddingTop: 20, paddingBottom: 32,
    borderTopWidth: 1, borderTopColor: COLORS.border,
  },
  calTitle:     { fontFamily: FONTS.title, fontSize: 20, color: COLORS.text, textAlign: 'center', marginBottom: 12 },
  calClose:     { marginTop: 16, alignItems: 'center' },
  calCloseText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },

  // GPS location card
  locationLoadingRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 12, marginBottom: 10 },
  locationLoadingText: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted },
  locationCard: {
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: 'rgba(0,230,118,0.08)', borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingHorizontal: 14, paddingVertical: 12, marginBottom: 10,
  },
  locationCardCity:   { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text },
  locationCardEstado: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted, marginTop: 2 },
  locationEditBtn:     { paddingHorizontal: 10, paddingVertical: 6 },
  locationEditBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },

  // Map address picker
  mapPickerBtn: {
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: COLORS.green,
    paddingVertical: 14, paddingHorizontal: 14, marginBottom: 8,
    alignItems: 'center',
  },
  mapPickerBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.green },

  addressCard: {
    flexDirection: 'row', alignItems: 'flex-start', gap: 10,
    backgroundColor: 'rgba(0,230,118,0.08)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.35)',
    paddingVertical: 12, paddingHorizontal: 14, marginBottom: 8,
  },
  addressCardText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text, lineHeight: 18 },
  addressCardSub:  { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 2 },
  addressCardEdit: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green, marginLeft: 4 },

  manualFallback:     { alignSelf: 'center', paddingVertical: 6, marginBottom: 4 },
  manualFallbackText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  useMapBtn:     { alignSelf: 'flex-start', paddingVertical: 6, marginTop: 4, marginBottom: 4 },
  useMapBtnText: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.green },

  warnBox:  { backgroundColor: 'rgba(239,83,80,0.10)', borderRadius: RADIUS.sm, padding: 10, marginTop: 6, borderWidth: 1, borderColor: 'rgba(239,83,80,0.3)' },
  warnText: { fontFamily: FONTS.body, fontSize: 12, color: '#EF5350', lineHeight: 17 },

  // ── Proximity banners ─────────────────────────────────────────────────────
  proximityOk: {
    backgroundColor: 'rgba(0,230,118,0.07)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.20)',
    paddingHorizontal: 14, paddingVertical: 10, marginTop: 4, marginBottom: 8,
  },
  proximityOkText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.green },

  proximityWarn: {
    backgroundColor: 'rgba(245,158,11,0.10)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(245,158,11,0.30)',
    paddingHorizontal: 14, paddingVertical: 12, marginTop: 4, marginBottom: 8,
  },
  proximityWarnText: { fontFamily: FONTS.body, fontSize: 13, color: '#F59E0B', lineHeight: 18 },

  proximityBlock: {
    backgroundColor: 'rgba(183,28,28,0.08)',
    borderRadius: RADIUS.lg, borderWidth: 1, borderColor: 'rgba(183,28,28,0.25)',
    padding: 18, marginTop: 4, marginBottom: 8, gap: 14,
  },
  proximityBlockTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 15, color: '#EF5350' },
  proximityBlockBody:  { fontFamily: FONTS.body, fontSize: 13, color: COLORS.muted2, lineHeight: 20 },
  proximityExpressBtn: {
    backgroundColor: COLORS.green, borderRadius: RADIUS.lg,
    paddingVertical: 14, alignItems: 'center' as const,
  },
  proximityExpressBtnText: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.bg },
  proximityBypassLink: { alignSelf: 'center' as const, paddingVertical: 6 },
  proximityBypassLinkText: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted,
    textDecorationLine: 'underline' as const,
  },

  proximityPast: {
    backgroundColor: 'rgba(239,83,80,0.10)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(239,83,80,0.30)',
    paddingHorizontal: 14, paddingVertical: 12, marginTop: 4, marginBottom: 8,
  },
  proximityPastText: { fontFamily: FONTS.bodySemiBold, fontSize: 13, color: '#EF5350' },

  // ── Extra hours hint ──────────────────────────────────────────────────────
  extraHoursHint: {
    backgroundColor: 'rgba(255,179,0,0.06)',
    borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: 'rgba(255,179,0,0.22)',
    paddingHorizontal: 12, paddingVertical: 10, marginTop: 4, marginBottom: 10,
  },
  extraHoursHintText: {
    fontFamily: FONTS.body, fontSize: 12, color: '#FFB300', lineHeight: 18,
  },

  // ── Tipo de descanso ──────────────────────────────────────────────────────
  breakOptions:  { gap: 8, marginBottom: 4 },
  breakOpt: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 12,
  },
  breakOptActive: { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)' },
  breakOptLabel:  { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text, marginBottom: 2 },
  breakOptDesc:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2 },

  // ── Sección 10 equipo ──────────────────────────────────────────────────────
  equipSubTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 13, color: COLORS.text,
    marginTop: 16, marginBottom: 8,
  },
  optionalTag: {
    fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted2,
  },
  equipOptCol: {
    alignItems: 'flex-start', marginBottom: 6,
  },
  inclusionGreen: {
    fontFamily: FONTS.body, fontSize: 10, color: COLORS.green,
    marginTop: 3, marginLeft: 4,
  },
  inclusionOrange: {
    fontFamily: FONTS.body, fontSize: 10, color: '#FFB300',
    marginTop: 3, marginLeft: 4,
  },
  equipSummaryBox: {
    backgroundColor: 'rgba(0,230,118,0.06)',
    borderRadius: RADIUS.md, borderWidth: 1, borderColor: 'rgba(0,230,118,0.20)',
    padding: 12, marginTop: 14, marginBottom: 4,
  },
  equipSummaryText: {
    fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, lineHeight: 18,
  },
});
