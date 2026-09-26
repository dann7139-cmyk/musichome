// ─────────────────────────────────────────────────────────────────────────────
// EventInfoScreen — Fase 1 de "Mi Evento" (sql/685)
//
// Alcance DELIBERADAMENTE chico: capturar y editar la información básica del
// evento que ya existe (public.events), nada más. NO es la experiencia completa
// de "Mi Evento" (cronograma, plan de abonos, paquetes, beneficios): eso es de
// fases posteriores y aquí no se construye ni se insinúa.
//
// Se llega desde el encabezado "Mi evento" de ReservationsScreen (cliente), que
// es donde el evento ya se muestra agrupado — no se inventó un punto de entrada
// nuevo.
//
// ── Sistema visual ──────────────────────────────────────────────────────────
// Sigue el estándar de pantalla tipo FORMULARIO que theme.ts documenta y que
// QuoteFormScreen ya implementa, para que se sienta la misma app:
//   · header: botón de regreso en caja de 40×40 (radius 12, COLORS.card,
//     borde), título a la IZQUIERDA en bodySemiBold 16 + subtítulo 12 muted2,
//     con borde inferior. (theme.ts: "FORMULARIO → bodySemiBold 16px izquierda")
//   · SectionTitle bodySemiBold 14 con marginTop 24 / marginBottom 12
//   · chips: radius lg, COLORS.card + borde; activo = verde 12% + borde verde,
//     texto bodyMedium 13 muted2 → verde (mismo chipWide/chipActive/chipText
//     de QuoteFormScreen, sin cambiar el peso de la fuente al activarse)
//   · hora: mismo comportamiento que el timeChip de QuoteFormScreen (cuando
//     tiene valor se pone verde)
//   · Input / Button / TimePickerModal de components/ui — componentes que ya
//     existen, sin librerías nuevas
// Daricefy es oscuro únicamente: la paleta clara CLIENT_COLORS existe en
// theme.ts pero NO se importa en ningún archivo del proyecto y no hay contexto
// de tema, así que aquí se usa COLORS como en todas las demás pantallas.
//
// Fecha, hora de inicio y dirección se muestran SOLO DE LECTURA a propósito:
// son la identidad del evento que usan los candados de proveedores y viven
// duplicadas en reservations/quotes. Cambiarlas es una fase aparte.
// ─────────────────────────────────────────────────────────────────────────────
import { ArrowLeft, Clock } from 'lucide-react-native';
import React, { useCallback, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from '../../components/ui/Button';
import Input from '../../components/ui/Input';
import TimePickerModal from '../../components/ui/TimePickerModal';

// Mismos 6 valores del CHECK de events.event_type / quotes.event_type, y las
// mismas etiquetas traducidas que ya usa el formulario de cotización.
const EVENT_TYPE_KEYS = ['fiesta_privada', 'boda', 'cumpleanos', 'graduacion', 'empresarial', 'otro'] as const;

const onlyDigits = (s: string) => s.replace(/[^0-9]/g, '');

// Mismo componente de encabezado de sección que usa QuoteFormScreen.
function SectionTitle({ children }: { children: React.ReactNode }) {
  return <Text style={s.sectionTitle}>{children}</Text>;
}

export default function EventInfoScreen({ route, navigation }: any) {
  const { t, i18n } = useTranslation();
  const { eventId } = route?.params ?? {};
  const dateLocale = i18n.language?.startsWith('en') ? 'en-US' : 'es-MX';

  const [loading, setLoading] = useState(true);
  const [saving, setSaving]   = useState(false);
  const [notFound, setNotFound] = useState(false);

  // Contexto de solo lectura
  const [eventDate, setEventDate] = useState<string | null>(null);
  const [startTime, setStartTime] = useState<string | null>(null);
  const [address,   setAddress]   = useState<string | null>(null);

  // Campos editables (Fase 1)
  const [name,      setName]      = useState('');
  const [eventType, setEventType] = useState<string | null>(null);
  const [guests,    setGuests]    = useState('');
  const [budget,    setBudget]    = useState('');
  const [currency,  setCurrency]  = useState<string | null>(null);
  const [endTime,   setEndTime]   = useState('');
  const [municipio, setMunicipio] = useState('');
  const [estado,    setEstado]    = useState('');

  const [timeOpen, setTimeOpen] = useState(false);

  const fetchEvent = useCallback(async () => {
    if (!eventId) { setNotFound(true); setLoading(false); return; }
    // select('*') a propósito: si sql/685 todavía no está aplicado en esta base,
    // nombrar las columnas nuevas daría error 42703 y la pantalla no abriría.
    // Así los campos simplemente llegan undefined y el formulario sale vacío.
    const { data, error } = await supabase
      .from('events')
      .select('*')
      .eq('id', eventId)
      .maybeSingle();

    if (error || !data) { setNotFound(true); setLoading(false); return; }

    setEventDate(data.event_date ?? null);
    setStartTime(data.event_time ? String(data.event_time).substring(0, 5) : null);
    setAddress(data.address ?? null);

    setName(data.name ?? '');
    setEventType(data.event_type ?? null);
    setGuests(data.guest_count != null ? String(data.guest_count) : '');
    setBudget(data.budget_max != null ? String(data.budget_max) : '');
    setCurrency(data.budget_currency ?? null);
    setEndTime(data.end_time ? String(data.end_time).substring(0, 5) : '');
    setMunicipio(data.event_municipio ?? '');
    setEstado(data.event_estado ?? '');
    setLoading(false);
  }, [eventId]);

  // useFocusEffect y no useEffect: es el patrón que ya usa el resto del
  // proyecto (ReservationsScreen, QuoteFormScreen) y además recarga si el
  // cliente vuelve a esta pantalla.
  useFocusEffect(useCallback(() => { fetchEvent(); }, [fetchEvent]));

  // Único estado inválido que la UI permite teclear (los campos ya filtran a
  // dígitos): escribir un 0 de invitados. Se avisa en el propio campo con el
  // prop `error` que Input ya soporta, en vez de dejar que el viaje al servidor
  // regrese un Alert.
  const guestsError = guests !== '' && parseInt(guests, 10) === 0
    ? t('eventInfo.errors.invalidGuests')
    : undefined;

  const save = async () => {
    if (guestsError) return;
    setSaving(true);
    const guestsNum = guests.trim() ? parseInt(onlyDigits(guests), 10) : null;
    const budgetNum = budget.trim() ? parseInt(onlyDigits(budget), 10) : null;

    // La RPC hace un reemplazo COMPLETO de los 8 campos: el formulario se manda
    // entero siempre, así que dejar un campo vacío de verdad lo borra.
    const { data, error } = await supabase.rpc('client_update_event_details', {
      p_event_id:        eventId,
      p_name:            name.trim() || null,
      p_event_type:      eventType,
      p_guest_count:     guestsNum,
      p_budget_max:      budgetNum,
      p_budget_currency: currency,
      p_end_time:        endTime || null,
      p_municipio:       municipio.trim() || null,
      p_estado:          estado.trim() || null,
    });
    setSaving(false);

    if (error || !data?.ok) {
      const code = data?.error ?? error?.message ?? '';
      const key =
        code.includes('invalid_event_type')        ? 'eventInfo.errors.invalidType'
        : code.includes('invalid_guest_count')     ? 'eventInfo.errors.invalidGuests'
        : code.includes('invalid_budget')          ? 'eventInfo.errors.invalidBudget'
        : code.includes('invalid_end_time')        ? 'eventInfo.errors.invalidEndTime'
        : code.includes('event_not_owned_by_client') ? 'eventInfo.errors.notOwner'
        : code.includes('event_not_found')         ? 'eventInfo.errors.notFound'
        : 'eventInfo.errors.generic';
      Alert.alert(t('eventInfo.errors.title'), t(key));
      return;
    }

    // Se devuelve la moneda que la base terminó usando (la deriva del país del
    // cliente cuando la app no la manda) para que el siguiente guardado ya
    // vaya con ella.
    if (data.budget_currency) setCurrency(data.budget_currency);
    Alert.alert(t('eventInfo.savedTitle'), t('eventInfo.savedBody'), [
      { text: 'OK', onPress: () => navigation.goBack() },
    ]);
  };

  const prettyDate = eventDate
    ? new Date(eventDate + 'T12:00:00').toLocaleDateString(dateLocale, { day: 'numeric', month: 'long', year: 'numeric' })
    : '—';

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable style={s.backBtn} onPress={() => navigation.goBack()} hitSlop={6}>
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <View style={{ flex: 1 }}>
          <Text style={s.headerTitle}>{t('eventInfo.headerTitle')}</Text>
          {!loading && !notFound && <Text style={s.headerSub}>{prettyDate}</Text>}
        </View>
      </SafeAreaView>

      {loading ? (
        <View style={s.center}><ActivityIndicator color={COLORS.green} /></View>
      ) : notFound ? (
        <View style={s.center}><Text style={s.muted}>{t('eventInfo.errors.notFound')}</Text></View>
      ) : (
        <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
          <ScrollView contentContainerStyle={s.scroll} keyboardShouldPersistTaps="handled">
            {/* Contexto de solo lectura — la fecha ya vive en el subtítulo del
                header, así que aquí no se repite: solo hora de inicio,
                dirección y la nota de por qué no se editan. */}
            <View style={s.contextCard}>
              {!!startTime && (
                <Text style={s.contextLine}>{t('eventInfo.startsAt', { time: startTime })}</Text>
              )}
              {!!address && <Text style={s.contextLine} numberOfLines={2}>📍 {address}</Text>}
              <Text style={s.contextNote}>{t('eventInfo.readOnlyNote')}</Text>
            </View>

            {/* ─── 1. EL EVENTO ───────────────────────────────────── */}
            <SectionTitle>{t('eventInfo.section1Title')}</SectionTitle>

            <Input
              label={t('eventInfo.nameLabel')}
              placeholder={t('eventInfo.namePlaceholder')}
              value={name}
              onChangeText={setName}
              maxLength={80}
            />

            <Text style={s.fieldLabel}>{t('eventInfo.typeLabel')}</Text>
            <View style={s.chipGrid}>
              {EVENT_TYPE_KEYS.map(key => {
                const active = eventType === key;
                return (
                  <Pressable
                    key={key}
                    style={[s.chipWide, active && s.chipActive]}
                    onPress={() => setEventType(active ? null : key)}
                  >
                    <Text style={[s.chipText, active && s.chipTextActive]}>
                      {t(`quoteFormScreen.eventTypes.${key}`)}
                    </Text>
                  </Pressable>
                );
              })}
            </View>

            {/* ─── 2. TAMAÑO Y PRESUPUESTO ────────────────────────── */}
            <SectionTitle>{t('eventInfo.section2Title')}</SectionTitle>

            <Input
              label={t('eventInfo.guestsLabel')}
              placeholder={t('eventInfo.guestsPlaceholder')}
              value={guests}
              onChangeText={v => setGuests(onlyDigits(v))}
              keyboardType="number-pad"
              maxLength={6}
              error={guestsError}
            />

            <Input
              label={t('eventInfo.budgetLabel', { currency: currency ?? '' }).trim()}
              placeholder={t('eventInfo.budgetPlaceholder')}
              value={budget}
              onChangeText={v => setBudget(onlyDigits(v))}
              keyboardType="number-pad"
              maxLength={9}
              icon={<Text style={s.currencyAdornment}>$</Text>}
            />
            <Text style={s.hint}>{t('eventInfo.budgetHint')}</Text>

            {/* ─── 3. CUÁNDO TERMINA Y DÓNDE ──────────────────────── */}
            <SectionTitle>{t('eventInfo.section3Title')}</SectionTitle>

            <Text style={s.fieldLabel}>{t('eventInfo.endTimeLabel')}</Text>
            <Pressable
              style={[s.timeChip, !!endTime && s.timeChipActive]}
              onPress={() => setTimeOpen(true)}
            >
              <Clock size={16} color={endTime ? COLORS.green : COLORS.muted2} />
              <Text style={[s.timeChipText, !!endTime && s.timeChipTextActive]}>
                {endTime || t('eventInfo.endTimePlaceholder')}
              </Text>
              {!!endTime && (
                <Pressable onPress={() => setEndTime('')} hitSlop={10}>
                  <Text style={s.clearText}>{t('eventInfo.clear')}</Text>
                </Pressable>
              )}
            </Pressable>
            <Text style={s.hint}>{t('eventInfo.endTimeHint')}</Text>

            <Input
              label={t('eventInfo.municipioLabel')}
              placeholder={t('eventInfo.municipioPlaceholder')}
              value={municipio}
              onChangeText={setMunicipio}
              maxLength={60}
            />
            <Input
              label={t('eventInfo.estadoLabel')}
              placeholder={t('eventInfo.estadoPlaceholder')}
              value={estado}
              onChangeText={setEstado}
              maxLength={60}
            />

            <View style={{ height: 12 }} />
            <Button label={t('eventInfo.save')} onPress={save} loading={saving} disabled={!!guestsError} />
            <Text style={s.footerNote}>{t('eventInfo.optionalNote')}</Text>
            <View style={{ height: 40 }} />
          </ScrollView>
        </KeyboardAvoidingView>
      )}

      <TimePickerModal
        visible={timeOpen}
        value={endTime || '23:00'}
        title={t('eventInfo.endTimeLabel')}
        onConfirm={(val: string) => { setEndTime(val); setTimeOpen(false); }}
        onClose={() => setTimeOpen(false)}
      />
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },

  // ── Header estándar de FORMULARIO (theme.ts) ──────────────────────────────
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

  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: SPACING.xl },
  muted:  { fontFamily: FONTS.body, fontSize: 14, color: COLORS.muted2, textAlign: 'center' },

  scroll: { padding: SPACING.xl, paddingBottom: 60 },

  // ── Contexto de solo lectura ──────────────────────────────────────────────
  contextCard: {
    backgroundColor: COLORS.card, borderRadius: RADIUS.lg,
    borderWidth: 1, borderColor: COLORS.border,
    padding: 14, gap: 4,
  },
  contextLine: { fontFamily: FONTS.body, fontSize: 13, color: COLORS.text },
  contextNote: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 4, lineHeight: 16 },

  sectionTitle: {
    fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.text,
    marginTop: 24, marginBottom: 12,
  },
  // Mismo tamaño/peso/color que el label interno de Input, para que los campos
  // que no son Input (tipo de evento, hora) no se vean de otra familia.
  fieldLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 8 },
  hint: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: -8, marginBottom: 16, lineHeight: 16 },
  footerNote: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 10, textAlign: 'center', lineHeight: 16 },

  currencyAdornment: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },

  // ── Chips (mismo vocabulario que QuoteFormScreen) ─────────────────────────
  // Única desviación deliberada: la superficie es COLORS.card2 y no COLORS.card.
  // QuoteFormScreen usa card porque sus campos de texto también son card (son
  // TextInput propios); aquí los campos son el componente compartido Input, que
  // es card2 por dentro. Dejar los chips en card los haría ver de otro tono que
  // los campos de arriba, en la misma pantalla. Se alinean TODOS los controles
  // interactivos a card2 y se reserva card para la tarjeta informativa de
  // contexto, que no se toca. No se modificó Input (lo comparten Login/Registro).
  chipGrid: { flexDirection: 'row', gap: 10, flexWrap: 'wrap', marginBottom: 4 },
  chipWide: {
    paddingHorizontal: 14, paddingVertical: 10,
    borderRadius: RADIUS.lg,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  chipActive:     { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: COLORS.green },
  chipText:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  chipTextActive: { color: COLORS.green },

  // ── Hora (mismo timeChip que QuoteFormScreen) ─────────────────────────────
  timeChip: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, paddingVertical: 15, marginBottom: 10,
  },
  timeChipActive:     { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)' },
  timeChipText:       { fontFamily: FONTS.body, fontSize: 15, color: COLORS.muted2, flex: 1 },
  timeChipTextActive: { fontFamily: FONTS.bodySemiBold, color: COLORS.green },
  clearText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },
});
