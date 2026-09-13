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
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import TimePickerModal from '../../components/ui/TimePickerModal';
import MapAddressPicker, { AddressResult } from '../../components/ui/MapAddressPicker';
import { analyzeMessage, PHONE_WARNING } from '../../utils/phoneFilter';
import { checkGroupLogistics } from '../../utils/logistics';
import { containsBlockedContact } from '../../utils/contentModeration';
import { getClientActiveEvents, resolveEventContext } from '../../utils/eventBuilder';
import i18n from '../../i18n';

// ─── Opciones ────────────────────────────────────────────────────────────────
// Se generan con `t` dentro del componente (useMemo) para reaccionar a cambios de idioma.

type TFn = (key: string, options?: Record<string, any>) => string;

const getEventTypes = (t: TFn) => [
  { key: 'fiesta_privada', label: t('quoteFormScreen.eventTypes.fiesta_privada') },
  { key: 'boda',           label: t('quoteFormScreen.eventTypes.boda') },
  { key: 'cumpleanos',     label: t('quoteFormScreen.eventTypes.cumpleanos') },
  { key: 'graduacion',     label: t('quoteFormScreen.eventTypes.graduacion') },
  { key: 'empresarial',    label: t('quoteFormScreen.eventTypes.empresarial') },
  { key: 'otro',           label: t('quoteFormScreen.eventTypes.otro') },
];

// Mínimo 3 horas por regla del negocio
const getDurationOptions = (t: TFn) => [
  { value: 3,  label: t('quoteFormScreen.durationOptions.h3') },
  { value: 4,  label: t('quoteFormScreen.durationOptions.h4') },
  { value: 5,  label: t('quoteFormScreen.durationOptions.h5') },
  { value: 6,  label: t('quoteFormScreen.durationOptions.h6') },
  { value: 7,  label: t('quoteFormScreen.durationOptions.h7') },
  { value: 8,  label: t('quoteFormScreen.durationOptions.h8') },
];

const getCoveredOptions = (t: TFn) => [
  { key: 'si',    label: t('quoteFormScreen.coveredOptions.si') },
  { key: 'no',    label: t('quoteFormScreen.coveredOptions.no') },
  { key: 'no_se', label: t('quoteFormScreen.coveredOptions.no_se') },
];

const getVenueSizes = (t: TFn) => [
  { key: 'patio_pequeno',         label: t('quoteFormScreen.venueSizes.patio_pequeno') },
  { key: 'salon_mediano',         label: t('quoteFormScreen.venueSizes.salon_mediano') },
  { key: 'jardin_grande',         label: t('quoteFormScreen.venueSizes.jardin_grande') },
  { key: 'escenario_profesional', label: t('quoteFormScreen.venueSizes.escenario_profesional') },
];

const getSoundOptions = (t: TFn) => [
  { key: 'no_group_brings', label: t('quoteFormScreen.soundOptions.no_group_brings') },
  { key: 'si_50',           label: t('quoteFormScreen.soundOptions.si_50') },
  { key: 'si_100',          label: t('quoteFormScreen.soundOptions.si_100') },
  { key: 'si_200',          label: t('quoteFormScreen.soundOptions.si_200') },
  { key: 'si_300',          label: t('quoteFormScreen.soundOptions.si_300') },
];

const getLightingOptions = (t: TFn) => [
  { key: 'no',      label: t('quoteFormScreen.lightingOptions.no') },
  { key: 'simple',  label: t('quoteFormScreen.lightingOptions.simple') },
  { key: 'pro',     label: t('quoteFormScreen.lightingOptions.pro') },
  { key: 'premium', label: t('quoteFormScreen.lightingOptions.premium') },
];

const getStageOptions = (t: TFn) => [
  { key: 'no',      label: t('quoteFormScreen.stageOptions.no') },
  { key: 'small',   label: t('quoteFormScreen.stageOptions.small') },
  { key: 'medium',  label: t('quoteFormScreen.stageOptions.medium') },
  { key: 'wedding', label: t('quoteFormScreen.stageOptions.wedding') },
];

const getLedOptions = (t: TFn) => [
  { key: 'no',     label: t('quoteFormScreen.ledOptions.no') },
  { key: 'medium', label: t('quoteFormScreen.ledOptions.medium') },
  { key: 'large',  label: t('quoteFormScreen.ledOptions.large') },
  { key: 'xl',     label: t('quoteFormScreen.ledOptions.xl') },
];

const getBreakOptions = (t: TFn) => [
  { type: 'A', label: t('quoteFormScreen.breakOptions.typeA.label'), desc: t('quoteFormScreen.breakOptions.typeA.desc') },
  { type: 'B', label: t('quoteFormScreen.breakOptions.typeB.label'), desc: t('quoteFormScreen.breakOptions.typeB.desc') },
  { type: 'D', label: t('quoteFormScreen.breakOptions.typeD.label'), desc: t('quoteFormScreen.breakOptions.typeD.desc') },
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

type InclusionLabel = 'included' | 'extra';

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
    if (value === 'no_group_brings') return 'included';
    if (!equip.has_sound) return 'extra';
    const capMap: Record<string, number> = { si_50: 50, si_100: 100, si_200: 200, si_300: 300 };
    return (capMap[value] ?? 0) <= (equip.sound_capacity_max ?? 0)
      ? 'included' : 'extra';
  }
  if (category === 'lighting') {
    if (value === 'no') return null;
    if (!equip.has_lighting) return 'extra';
    const clientLevel = LIGHTING_HIERARCHY[value] ?? 0;
    const groupLevel  = LIGHTING_HIERARCHY[equip.lighting_level ?? ''] ?? 0;
    return clientLevel <= groupLevel ? 'included' : 'extra';
  }
  if (category === 'stage') {
    if (value === 'no') return null;
    if (!equip.has_stage) return 'extra';
    return equip.stage_sizes_available.includes(value) ? 'included' : 'extra';
  }
  if (category === 'led') {
    if (value === 'no') return null;
    if (!equip.has_led_screen) return 'extra';
    return equip.led_sizes_available.includes(value) ? 'included' : 'extra';
  }
  return null;
}

// Géneros sin "horario de show" — petición explícita del usuario
// (2026-09-01): "la comida esa si es a la hora que sea y brincolines o
// muebles esas dos últimas no llevan temporizador". Comida es a
// cualquier hora; brincolines/inflables y renta de mesas/sillas no
// tienen concepto de horario. Mismos valores EXACTOS de
// EventCategoryPickerScreen.tsx (deben coincidir con groups.genre).
// El resto de "renta" (escenarios, generadores, plantas de luz,
// toldos, tarimas) NO quedó exento — el usuario no lo mencionó.
const TIMELESS_GENRES = [
  'Comida', 'Renta de brincolines', 'Inflables acuáticos',
  'Renta de mesas', 'Renta de sillas',
];

// ─── Screen ──────────────────────────────────────────────────────────────────

export default function QuoteFormScreen({ route, navigation }: any) {
  const { t } = useTranslation();
  const { group } = route.params as { group: any };
  // sql/585 (Fase 1) — contexto de "agregar otro proveedor al mismo evento".
  // presetEventId solo llega si el cliente vino de HomeScreen/GroupDetail
  // con un evento activo; en el uso normal (cotización nueva, sin evento
  // previo) queda null y nada de esto se activa.
  const presetEventId      = route.params?.eventId ?? null;
  const presetEventDate    = route.params?.eventDate ?? null;
  const presetEventAddress = route.params?.eventAddress ?? null;
  const [soundContext, setSoundContext] = useState<{ has_prior_declarations: boolean; declared_by?: string[] } | null>(null);
  // sql/596 — este proveedor (`group`) ¿tiene horario de show que pueda
  // chocar con otro proveedor del mismo evento? Comida/brincolines/muebles no.
  const isTimedProvider = !TIMELESS_GENRES.includes(group.genre);
  // Horarios ya tomados por OTROS proveedores "con temporizador" del mismo
  // evento (sql/596) — para que el cliente no elija una hora que se encime.
  const [eventConflictRanges, setEventConflictRanges] = useState<{ bs: number; be: number; group_name: string }[]>([]);

  const eventTypeOptions    = useMemo(() => getEventTypes(t), [t]);
  const durationOptions     = useMemo(() => getDurationOptions(t), [t]);
  const coveredOptions      = useMemo(() => getCoveredOptions(t), [t]);
  const venueSizeOptions    = useMemo(() => getVenueSizes(t), [t]);
  const soundOptionsList    = useMemo(() => getSoundOptions(t), [t]);
  const lightingOptionsList = useMemo(() => getLightingOptions(t), [t]);
  const stageOptionsList    = useMemo(() => getStageOptions(t), [t]);
  const ledOptionsList      = useMemo(() => getLedOptions(t), [t]);
  const breakOptionsList    = useMemo(() => getBreakOptions(t), [t]);

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

  // sql/585 (Fase 1) — prellenar fecha/dirección del evento existente (sugerencia,
  // no bloquea los campos: el cliente puede ajustarlos si lo necesita) y
  // traer el sonido ya declarado por otros proveedores del mismo evento como
  // REFERENCIA. Nunca escribe en needsSound/lightingNeeded/etc — cada
  // proveedor conserva su propia declaración, esto es solo informativo.
  useEffect(() => {
    if (presetEventDate) setEventDate(presetEventDate);
    if (presetEventAddress) setAddress(presetEventAddress);
    if (!presetEventId) return;
    supabase.rpc('client_get_event_sound_context', { p_event_id: presetEventId })
      .then(({ data, error }) => {
        // RPC de sql/585 — todavía no existe en producción hasta que se aplique.
        // Si falla (no existe / sin permiso), simplemente no se muestra el banner.
        if (!error && data?.ok) setSoundContext(data);
      });
  }, [presetEventId, presetEventDate, presetEventAddress]);

  // sql/596 — traer los horarios ya tomados por otros proveedores del mismo
  // evento (solo si ESTE proveedor tiene horario de show; comida/brincolines/
  // muebles no lo necesitan). Si falla, simplemente no se muestra el aviso.
  useEffect(() => {
    if (!presetEventId || !isTimedProvider) { setEventConflictRanges([]); return; }
    supabase.rpc('client_get_event_time_conflicts', { p_event_id: presetEventId, p_exclude_group_id: group.id })
      .then(({ data, error }) => {
        if (error || !data?.ok) { setEventConflictRanges([]); return; }
        const parsed = (data.ranges ?? []).map((r: any) => {
          const [hh, mm] = String(r.time).split(':').map(Number);
          const bs = hh + (mm || 0) / 60;
          return { bs, be: bs + Number(r.hours ?? 3), group_name: r.group_name as string };
        });
        setEventConflictRanges(parsed);
      });
  }, [presetEventId, isTimedProvider, group.id]);

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

  // Formatea una hora fraccionaria (ej. 13.5 = 1:30pm) — usado para los
  // rangos de eventConflictRanges (sql/596), que vienen en horas decimales.
  const fmtHourFrac = (hf: number) => {
    const hh = Math.floor(hf) % 24;
    const mm = Math.round((hf - Math.floor(hf)) * 60);
    const ampm = hh >= 12 ? 'PM' : 'AM';
    const h12 = hh % 12 || 12;
    return `${h12}:${String(mm).padStart(2, '0')} ${ampm}`;
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

  // sql/596 — ¿un evento de durH horas iniciando en startH se encima con
  // OTRO proveedor del mismo evento compartido? Sin colchón (gap=0): son
  // grupos independientes, uno puede empezar justo cuando el otro termina.
  const eventConflictAt = (startH: number, durH: number) =>
    eventConflictRanges.some(r => startH < r.be && startH + durH > r.bs);

  // ── Enviar ───────────────────────────────────────────────────────────────
  const handleSubmit = async () => {
    if (!canSubmit()) {
      Alert.alert(t('quoteFormScreen.incompleteFieldsTitle'), t('quoteFormScreen.incompleteFieldsBody'));
      return;
    }

    if (comments.trim() && containsBlockedContact(comments)) {
      Alert.alert(i18n.t('moderation.title'), i18n.t('moderation.no_contact'));
      return;
    }

    if (isGift && !giftRecipient.trim()) {
      Alert.alert(t('quoteFormScreen.giftRecipientMissingTitle'), t('quoteFormScreen.giftRecipientMissingBody'));
      return;
    }

    const { data: { user } } = await supabase.auth.getUser();
    if (!user) { Alert.alert(t('quoteFormScreen.error'), t('quoteFormScreen.sessionNotFound')); return; }

    // sql/585 (Fase 1, ampliado 2026-09-06) — resolver SIEMPRE el contexto
    // de evento al pedir una cotización, no solo cuando se llega desde
    // "Agregar otro proveedor". Hallazgo real del cliente probando: pedir
    // cotización a un 2º grupo obligaba a repetir fecha/dirección/necesidades
    // desde cero porque la 1ª cotización nunca quedaba ligada a ningún
    // evento. Con esto, toda cotización (la primera incluida) crea o
    // reutiliza un event_id real — `events` ya existe hoy en producción
    // (no depende de sql/585), así que esta parte funciona sin esperar
    // ninguna autorización de SQL. Lo único que SÍ depende de sql/585 es
    // que `client_get_my_events()` ya sepa ofrecer "¿agregar a tu evento
    // activo?" para una cotización todavía pendiente (sin reserva) — hasta
    // entonces, esta pregunta automática no aparece, pero el botón explícito
    // "Agregar otro proveedor" SÍ funciona ya (viaja con presetEventId,
    // sin pasar por esa RPC).
    const activeEvents = presetEventId ? [] : await getClientActiveEvents();
    let resolvedEventId = await resolveEventContext({ t, presetEventId, activeEvents });
    if (!resolvedEventId) {
      const { data: newEvent, error: newEventErr } = await supabase
        .from('events')
        .insert({ client_id: user.id, event_date: eventDate, event_time: eventTime || null, address: address.trim(), status: 'active' })
        .select('id')
        .single();
      // Si falla, no bloquea el envío de la cotización — simplemente queda
      // sin event_id, igual que el comportamiento de siempre.
      if (!newEventErr && newEvent?.id) resolvedEventId = newEvent.id;
    }

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
    // sql/585 (Fase 1) — event_id todavía no es columna de `quotes` en
    // producción (columna nueva de sql/585, no aplicado). Si resolvedEventId
    // existe, se intenta incluirlo; si la columna no existe, se reintenta
    // sin ese campo para no romper la cotización normal. PostgREST reporta
    // columna desconocida como PGRST204 (schema cache), no como el 42703
    // de Postgres — se aceptan ambos por si el insert llegara vía otra ruta.
    let insertData: any = null;
    let error: any = null;
    if (resolvedEventId) {
      const withEventId = await supabase.from('quotes').insert({ ...insertPayload, event_id: resolvedEventId }).select('id');
      if (withEventId.error?.code === '42703' || withEventId.error?.code === 'PGRST204') {
        const fallback = await supabase.from('quotes').insert(insertPayload).select('id');
        insertData = fallback.data; error = fallback.error;
      } else {
        insertData = withEventId.data; error = withEventId.error;
      }
    } else {
      const res = await supabase.from('quotes').insert(insertPayload).select('id');
      insertData = res.data; error = res.error;
    }
    setLoading(false);

    if (error) {
      console.error('🔴 INSERT quote ERROR:', error);
      // Guards anti-spam (sql/484) lanzan mensajes legibles — mostrarlos limpios
      const emsg = error.message ?? '';
      if (emsg.includes('cotizaciones') || emsg.includes('límite') || emsg.includes('limite')) {
        Alert.alert(t('quoteFormScreen.waitMomentTitle'), emsg);
      } else {
        Alert.alert(
          t('quoteFormScreen.errorDetailedTitle'),
          `Code: ${error.code ?? '—'}\nMessage: ${emsg || '—'}\nDetails: ${error.details ?? '—'}\nHint: ${error.hint ?? '—'}`,
        );
      }
    } else {
      // Notificar — RPC server-side (sql/648, 2026-09-13). Antes esto era
      // 4 inserts a mano desde el cliente, siempre al dueño del grupo.
      // Ahora el RPC decide: si el grupo todavía está en "modo conserjería"
      // (no maneja su cuenta), avisa a Daniel/admin_ops de su país en vez
      // del dueño — el cliente nunca nota la diferencia.
      const newQuoteId = insertData?.[0]?.id ?? null;
      if (newQuoteId) {
        await supabase.rpc('notify_quote_request', { p_quote_id: newQuoteId });
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
        t('quoteFormScreen.requestSentTitle'),
        t('quoteFormScreen.requestSentBody', { groupName: group.name }),
        [{ text: t('quoteFormScreen.understood'), onPress: () => navigation.goBack() }],
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
        t('quoteFormScreen.logisticsConflictTitle'),
        logistics.messageClient ?? t('quoteFormScreen.logisticsConflictBody'),
      );
      return;
    }

    if (tightButPossible) {
      setLoading(false);
      Alert.alert(
        t('quoteFormScreen.tightTimeTitle'),
        t('quoteFormScreen.tightTimeBody'),
        [
          { text: t('quoteFormScreen.changeTimeBtn'), style: 'cancel' },
          { text: t('quoteFormScreen.sendAnywayBtn'), onPress: () => { setLoading(true); void sendQuote(); } },
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
          <Text style={s.headerTitle}>{t('quoteFormScreen.headerTitle')}</Text>
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
            <Text style={s.progressLabel}>{t('quoteFormScreen.progressLabel', { completed, total })}</Text>
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
              {t('quoteFormScreen.infoBanner')}
            </Text>
          </View>

          {/* sql/585 (Fase 1) — evento existente: solo aparece si el cliente
              viene de "agregar otro proveedor". Ausente en cotizaciones normales. */}
          {!!presetEventId && (
            <View style={s.infoBanner}>
              <Text style={s.infoBannerText}>
                {t('quoteFormScreen.eventContextBanner', {
                  date: presetEventDate ?? '—',
                  address: presetEventAddress ?? '',
                })}
              </Text>
            </View>
          )}

          {/* ─── 1. TIPO DE EVENTO ──────────────────────────────── */}
          <SectionTitle>{t('quoteFormScreen.section1Title')}</SectionTitle>
          <View style={s.chipGrid}>
            {eventTypeOptions.map(o => (
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
          <SectionTitle>{t('quoteFormScreen.section2Title')}</SectionTitle>

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
                <Text style={s.addressCardEdit}>{t('quoteFormScreen.addressChange')}</Text>
              </Pressable>
            </View>
          ) : showManualAddress ? (
            /* Manual input fallback */
            <>
              <TextInput
                style={s.input}
                placeholder={t('quoteFormScreen.addressPlaceholderFull')}
                placeholderTextColor={COLORS.muted}
                value={address}
                onChangeText={t => { setAddress(t); setAddressConfirmed(false); }}
              />
              <View style={s.row2}>
                <TextInput
                  style={[s.input, { flex: 1 }]}
                  placeholder={t('quoteFormScreen.municipioPlaceholder')}
                  placeholderTextColor={COLORS.muted}
                  value={municipio}
                  onChangeText={t => { setMunicipio(t); setAddressConfirmed(false); }}
                />
                <TextInput
                  style={[s.input, { flex: 1 }]}
                  placeholder={t('quoteFormScreen.estadoPlaceholder')}
                  placeholderTextColor={COLORS.muted}
                  value={estado}
                  onChangeText={t => { setEstado(t); setAddressConfirmed(false); }}
                />
              </View>
              <Pressable onPress={() => setMapPickerOpen(true)} style={s.useMapBtn}>
                <Text style={s.useMapBtnText}>{t('quoteFormScreen.useMapBtn')}</Text>
              </Pressable>
            </>
          ) : (
            /* Default: open map picker */
            <>
              <Pressable style={s.mapPickerBtn} onPress={() => setMapPickerOpen(true)}>
                <Text style={s.mapPickerBtnText}>{t('quoteFormScreen.selectOnMapBtn')}</Text>
              </Pressable>
              <Pressable onPress={() => setShowManualAddress(true)} style={s.manualFallback}>
                <Text style={s.manualFallbackText}>{t('quoteFormScreen.writeManualAddress')}</Text>
              </Pressable>
            </>
          )}

          {/* ─── 3. FECHA ────────────────────────────────────────── */}
          <SectionTitle>{t('quoteFormScreen.section3Title')}</SectionTitle>
          <Pressable style={s.dateBtn} onPress={() => setCalendarOpen(true)}>
            <Text style={[s.dateBtnText, !eventDate && { color: COLORS.muted }]}>
              {eventDate
                ? new Date(eventDate + 'T12:00:00').toLocaleDateString('es-MX', { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' })
                : t('quoteFormScreen.selectDatePlaceholder')}
            </Text>
          </Pressable>

          {/* Aviso: el grupo ya tiene evento ese día (se puede contratar en otro horario) */}
          {eventDate && busyByDate[eventDate]?.length ? (
            <View style={s.busyNotice}>
              <Text style={s.busyNoticeTitle}>{t('quoteFormScreen.busyNoticeTitle')}</Text>
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
                    · {start
                      ? (end ? t('quoteFormScreen.busyRangeFull', { start, end }) : t('quoteFormScreen.busyRangeStart', { start }))
                      : t('quoteFormScreen.busyPending')}
                  </Text>
                );
              })}
              <Text style={s.busyNoticeHint}>
                {t('quoteFormScreen.busyNoticeHint')}
              </Text>
            </View>
          ) : null}

          {/* sql/596 — Aviso: otro proveedor de tu evento ya tiene hora (se
              excluyen comida/brincolines/muebles, que no tienen horario) */}
          {eventConflictRanges.length > 0 ? (
            <View style={s.busyNotice}>
              <Text style={s.busyNoticeTitle}>{t('quoteFormScreen.eventConflictNoticeTitle')}</Text>
              {eventConflictRanges.map((r, i) => (
                <Text key={i} style={s.busyNoticeLine}>
                  · {t('quoteFormScreen.eventConflictRangeLine', {
                    group: r.group_name, start: fmtHourFrac(r.bs), end: fmtHourFrac(r.be),
                  })}
                </Text>
              ))}
              <Text style={s.busyNoticeHint}>
                {t('quoteFormScreen.eventConflictNoticeHint')}
              </Text>
            </View>
          ) : null}

          {/* ─── 4. HORA ─────────────────────────────────────────── */}
          <SectionTitle>{t('quoteFormScreen.section4Title')}</SectionTitle>

          {/* Día con evento del grupo Y/O choque con otro proveedor del mismo
              evento (sql/596): rejilla de horas disponibles vs ocupadas */}
          {eventDate && ((busyByDate[eventDate]?.length ?? 0) > 0 || eventConflictRanges.length > 0) && (() => {
            const dur = duration ?? 3;
            const ranges = rangesFor(eventDate);
            const fmtH = (h: number) => { const hh = h % 24; return `${hh % 12 || 12}${hh >= 12 ? 'pm' : 'am'}`; };
            const slots: { h: number; status: 'free' | 'tight' | 'buffer' | 'busy' }[] = [];
            // h=24/25/26 = 12am/1am/2am (madrugada de esa noche) — tocadas nocturnas
            for (let h = 9; h <= 26; h++) {
              // La hora en que TERMINA la tocada también se pinta roja (h <= be)
              const insideBusy = ranges.some(r => h >= r.bs && h <= r.be);
              // sql/596 — ¿un evento de `dur` horas iniciando en `h` se encima
              // con otro proveedor del mismo evento? Sin colchón (gap=0).
              const insideEventConflict = eventConflictAt(h, dur);
              // Antes de otra tocada: 2h obligatorias ("muy cercana" = justo en
              // el límite). Después de una tocada: 1h de quitar sonido y traslado.
              const status = (insideBusy || insideEventConflict) ? 'busy'
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
                <Text style={s.hourGridTitle}>
                  {t(
                    (busyByDate[eventDate]?.length ?? 0) > 0
                      ? 'quoteFormScreen.hourGridTitle'
                      : 'quoteFormScreen.hourGridTitleEventOnly',
                    { dur },
                  )}
                </Text>
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
                  <Text style={s.hourLegendItem}>{t('quoteFormScreen.legendAvailable')}</Text>
                  <Text style={s.hourLegendItem}>{t('quoteFormScreen.legendTight')}</Text>
                  <Text style={s.hourLegendItem}>{t('quoteFormScreen.legendBusy')}</Text>
                  <Text style={s.hourLegendItem}>{t('quoteFormScreen.legendTransfer')}</Text>
                </View>
                {selSlot?.status === 'tight' ? (
                  <Text style={s.hourTightTx}>
                    {t('quoteFormScreen.hourTightNote')}
                  </Text>
                ) : afterPriorGig && selSlot ? (
                  <Text style={s.hourSuggestTx}>
                    {t('quoteFormScreen.hourAfterPriorGigNote')}
                  </Text>
                ) : firstFree.length > 0 && !eventTime ? (
                  <Text style={s.hourSuggestTx}>
                    {t('quoteFormScreen.hourSuggestTimes', { times: firstFree.map(fmtH).join(', ') })}
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
              {eventTime ? formatTime12h(eventTime) : t('quoteFormScreen.timeChipPlaceholder')}
            </Text>
          </Pressable>

          {/* ─── BANNER PROXIMIDAD — se muestra en tiempo real ──── */}
          {proximityLevel === 'ok' && (
            <View style={s.proximityOk}>
              <Text style={s.proximityOkText}>{t('quoteFormScreen.proximityOk')}</Text>
            </View>
          )}
          {proximityLevel === 'warn' && (
            <View style={s.proximityWarn}>
              <Text style={s.proximityWarnText}>
                {t('quoteFormScreen.proximityWarn')}
              </Text>
            </View>
          )}
          {proximityLevel === 'block' && !bypassProximityBlock && (
            <View style={s.proximityBlock}>
              <Text style={s.proximityBlockTitle}>{t('quoteFormScreen.proximityBlockTitle')}</Text>
              <Text style={s.proximityBlockBody}>
                {t('quoteFormScreen.proximityBlockBodyPart1')}
                <Text style={{ fontFamily: 'DMSans_600SemiBold' }}>{t('quoteFormScreen.proximityBlockBodyBold')}</Text>
                {t('quoteFormScreen.proximityBlockBodyPart2')}
              </Text>
              <Pressable
                style={s.proximityExpressBtn}
                onPress={() => navigation.navigate('OpenRequest' as any)}
              >
                <Text style={s.proximityExpressBtnText}>{t('quoteFormScreen.proximityExpressBtn')}</Text>
              </Pressable>
              <Pressable
                style={s.proximityBypassLink}
                onPress={() => {
                  Alert.alert(
                    t('quoteFormScreen.proximityBypassAlertTitle'),
                    t('quoteFormScreen.proximityBypassAlertBody'),
                    [
                      { text: t('quoteFormScreen.cancel'), style: 'cancel' },
                      {
                        text: t('quoteFormScreen.proximityBypassConfirm'),
                        style: 'destructive',
                        onPress: () => setBypassProximityBlock(true),
                      },
                    ],
                  );
                }}
              >
                <Text style={s.proximityBypassLinkText}>{t('quoteFormScreen.proximityBypassLink')}</Text>
              </Pressable>
            </View>
          )}
          {proximityLevel === 'past' && (
            <View style={s.proximityPast}>
              <Text style={s.proximityPastText}>
                {t('quoteFormScreen.proximityPast')}
              </Text>
            </View>
          )}

          {/* ─── 5. DURACIÓN ─────────────────────────────────────── */}
          <SectionTitle>{t('quoteFormScreen.section5Title')}  <Text style={s.minNote}>{t('quoteFormScreen.minNote')}</Text></SectionTitle>
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
            // sql/596 — duraciones que se encimarían con otro proveedor del
            // mismo evento (sin colchón, ver eventConflictAt)
            const eventConstrained = eventConflictRanges.length > 0 && selH != null;
            const anyBlockedByOwn = constrained &&
              durationOptions.some(d => !fitsWithGap(selH!, d.value, 2, ranges));
            const anyBlockedByEvent = eventConstrained &&
              durationOptions.some(d => eventConflictAt(selH!, d.value));
            return (
              <>
                <ChipRow
                  options={durationOptions.map(d => {
                    const blockedByOwn = constrained && !fitsWithGap(selH!, d.value, 2, ranges);
                    const blockedByEvent = eventConstrained && eventConflictAt(selH!, d.value);
                    return {
                      key: d.value, label: d.label,
                      ...(constrained || eventConstrained ? {
                        disabled: blockedByOwn || blockedByEvent,
                        warn:     !blockedByEvent && constrained &&
                                  fitsWithGap(selH!, d.value, 2, ranges) &&
                                  !fitsWithGap(selH!, d.value, 3, ranges),
                      } : {}),
                    };
                  })}
                  selected={duration}
                  onSelect={v => setDuration(Number(v))}
                />
                {anyBlockedByOwn ? (
                  <Text style={s.durLockTx}>
                    {t('quoteFormScreen.durationLockedNote')}
                  </Text>
                ) : anyBlockedByEvent ? (
                  <Text style={s.durLockTx}>
                    {t('quoteFormScreen.durationLockedNoteEvent')}
                  </Text>
                ) : null}
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
                    ? t('quoteFormScreen.extraHoursBoxedIn')
                    : t('quoteFormScreen.extraHoursTip')}
                </Text>
              </View>
            );
          })()}

          {/* ─── 6. TIPO DE DESCANSO — oculto: el grupo elige en EventTimerScreen */}
          {false && (<>
          <SectionTitle>{t('quoteFormScreen.section6Title')}</SectionTitle>
          <Text style={[s.minNote, { marginTop: -8, marginBottom: 12 }]}>
            {t('quoteFormScreen.section6Note')}
          </Text>
          <View style={s.breakOptions}>
            {breakOptionsList.map(opt => (
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
          <SectionTitle>{t('quoteFormScreen.section7Title')}</SectionTitle>
          <TextInput
            style={s.input}
            placeholder={t('quoteFormScreen.numPersonasPlaceholder')}
            placeholderTextColor={COLORS.muted}
            value={numPersonas}
            onChangeText={t => setNumPersonas(t.replace(/[^0-9]/g, ''))}
            keyboardType="numeric"
            maxLength={4}
          />

          {/* ─── 8. ¿TECHADO? ────────────────────────────────────── */}
          <SectionTitle>{t('quoteFormScreen.section8Title')}</SectionTitle>
          <ChipRow
            options={coveredOptions as any}
            selected={venueCovered}
            onSelect={setVenueCovered}
          />

          {/* ─── 9. ESPACIO ──────────────────────────────────────── */}
          <SectionTitle>{t('quoteFormScreen.section9Title')}</SectionTitle>
          <View style={s.chipGrid}>
            {venueSizeOptions.map(o => (
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
          <SectionTitle>{t('quoteFormScreen.section10Title')}</SectionTitle>

          {/* sql/585 (Fase 1) — referencia de sonido ya declarado por otro
              proveedor del mismo evento. Es solo informativo: NO prellena
              needsSound/lightingNeeded, y no impide que este proveedor
              declare algo distinto — cada uno conserva su propia respuesta. */}
          {!!soundContext?.has_prior_declarations && (
            <View style={s.soundRefBanner}>
              <Text style={s.soundRefBannerText}>
                {t('quoteFormScreen.soundContextBanner')}
                {!!soundContext.declared_by?.length && (
                  ` ${t('quoteFormScreen.soundContextBy', { names: soundContext.declared_by.join(', ') })}`
                )}
              </Text>
            </View>
          )}

          {/* Sonido */}
          <Text style={s.equipSubTitle}>{t('quoteFormScreen.equipSoundTitle')}</Text>
          <View style={s.chipRow}>
            {soundOptionsList.map(o => {
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
                    <Text style={lbl === 'included' ? s.inclusionGreen : s.inclusionOrange}>
                      {lbl === 'included' ? t('quoteFormScreen.included') : t('quoteFormScreen.extraQuote')}
                    </Text>
                  )}
                </View>
              );
            })}
          </View>

          {/* Iluminación */}
          <Text style={s.equipSubTitle}>{t('quoteFormScreen.equipLightingTitle')} <Text style={s.optionalTag}>{t('quoteFormScreen.optionalTag')}</Text></Text>
          <View style={s.chipRow}>
            {lightingOptionsList.map(o => {
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
                    <Text style={lbl === 'included' ? s.inclusionGreen : s.inclusionOrange}>
                      {lbl === 'included' ? t('quoteFormScreen.included') : t('quoteFormScreen.extraQuote')}
                    </Text>
                  )}
                </View>
              );
            })}
          </View>

          {/* Tarima */}
          <Text style={s.equipSubTitle}>{t('quoteFormScreen.equipStageTitle')} <Text style={s.optionalTag}>{t('quoteFormScreen.optionalTag')}</Text></Text>
          <View style={s.chipRow}>
            {stageOptionsList.map(o => {
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
                    <Text style={lbl === 'included' ? s.inclusionGreen : s.inclusionOrange}>
                      {lbl === 'included' ? t('quoteFormScreen.included') : t('quoteFormScreen.extraQuote')}
                    </Text>
                  )}
                </View>
              );
            })}
          </View>

          {/* LED */}
          <Text style={s.equipSubTitle}>{t('quoteFormScreen.equipLedTitle')} <Text style={s.optionalTag}>{t('quoteFormScreen.optionalTag')}</Text></Text>
          <View style={s.chipRow}>
            {ledOptionsList.map(o => {
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
                    <Text style={lbl === 'included' ? s.inclusionGreen : s.inclusionOrange}>
                      {lbl === 'included' ? t('quoteFormScreen.included') : t('quoteFormScreen.extraQuote')}
                    </Text>
                  )}
                </View>
              );
            })}
          </View>

          {/* Nota resumen */}
          <View style={s.equipSummaryBox}>
            <Text style={s.equipSummaryText}>
              {t('quoteFormScreen.equipSummaryLine1')}{'\n'}
              {t('quoteFormScreen.equipSummaryLine2')}
            </Text>
          </View>

          {/* ─── 11. COMENTARIOS ──────────────────────────────────── */}
          <SectionTitle>{t('quoteFormScreen.section11Title')}</SectionTitle>
          <TextInput
            style={[s.input, s.inputMulti]}
            placeholder={t('quoteFormScreen.commentsPlaceholder')}
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
          <Text style={s.charCount}>{t('quoteFormScreen.charCount', { count: comments.length })}</Text>
          {commentsWarn && (
            <View style={s.warnBox}>
              <Text style={s.warnText}>⚠️ {PHONE_WARNING}</Text>
            </View>
          )}

          {/* ─── 🎁 ¿ES UN REGALO? (switch opcional) ──────────────── */}
          <View style={s.giftToggleRow}>
            <View style={{ flex: 1 }}>
              <Text style={s.giftToggleTitle}>{t('quoteFormScreen.giftToggleTitle')}</Text>
              <Text style={s.giftToggleHint}>{t('quoteFormScreen.giftToggleHint')}</Text>
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
                {t('quoteFormScreen.giftBoxHint')}
              </Text>

              <Text style={s.giftLabel}>{t('quoteFormScreen.giftRecipientLabel')}</Text>
              <TextInput
                style={s.input}
                placeholder={t('quoteFormScreen.giftRecipientPlaceholder')}
                placeholderTextColor={COLORS.muted}
                value={giftRecipient}
                onChangeText={setGiftRecipient}
                maxLength={60}
              />

              <Text style={s.giftLabel}>{t('quoteFormScreen.giftMessageLabel')}</Text>
              <TextInput
                style={[s.input, s.inputMulti]}
                placeholder={t('quoteFormScreen.giftMessagePlaceholder')}
                placeholderTextColor={COLORS.muted}
                value={giftMessage}
                onChangeText={setGiftMessage}
                multiline
                maxLength={200}
                textAlignVertical="top"
              />

              <Text style={s.giftLabel}>{t('quoteFormScreen.giftContactLabel')}</Text>
              <TextInput
                style={s.input}
                placeholder={t('quoteFormScreen.giftContactPlaceholder')}
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
              {loading ? t('quoteFormScreen.submitting') : t('quoteFormScreen.submitBtn')}
            </Text>
          </Pressable>

          <View style={{ height: 40 }} />
        </ScrollView>
      </KeyboardAvoidingView>

      {/* ── Modal Calendario ─────────────────────────────────────────────────── */}
      <Modal visible={calendarOpen} transparent animationType="slide">
        <View style={s.calOverlay}>
          <View style={s.calSheet}>
            <Text style={s.calTitle}>{t('quoteFormScreen.calendarTitle')}</Text>
            <Calendar
              onDayPress={(day: any) => {
                if (unavailMarked[day.dateString]?.disabled) {
                  Alert.alert(t('quoteFormScreen.dateUnavailableTitle'), t('quoteFormScreen.dateUnavailableBody'));
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
              <Text style={s.calCloseText}>{t('quoteFormScreen.cancel')}</Text>
            </Pressable>
          </View>
        </View>
      </Modal>
      <TimePickerModal
        visible={timePickerOpen}
        value={eventTime}
        title={t('quoteFormScreen.timePickerTitle')}
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

  soundRefBanner: {
    backgroundColor: 'rgba(255,152,0,0.10)', borderWidth: 1, borderColor: 'rgba(255,152,0,0.30)',
    borderRadius: RADIUS.lg, padding: 12, marginBottom: 14,
  },
  soundRefBannerText: { fontFamily: FONTS.body, fontSize: 12, color: COLORS.orange, lineHeight: 18 },

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
