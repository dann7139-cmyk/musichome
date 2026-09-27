// ─────────────────────────────────────────────────────────────────────────────
// PartyBuilderScreen — Fase 2: "Arma tu fiesta"
//
// Punto de entrada para que el cliente arme un evento desde cero. Dos pasos, y
// al terminar lo deja en el hub de servicios que YA existe
// (EventCategoryPickerScreen), con el event_id en la mano — así el resto de la
// cadena que ya funciona (Explorar → GroupDetail → QuoteForm → cotización →
// aceptación) recibe el contexto sin ningún mecanismo nuevo.
//
// ── Reutiliza, no reinventa ─────────────────────────────────────────────────
//   · patrón de wizard + barra de progreso de GuidedRequestScreen
//   · header estándar de FORMULARIO documentado en theme.ts (botón de regreso
//     enmarcado 40×40, título a la izquierda bodySemiBold 16 + subtítulo 12)
//   · MapAddressPicker (devuelve address/municipio/estado/lat/lng)
//   · Calendar de react-native-calendars con el mismo tema que QuoteFormScreen
//   · TimePickerModal, Input, Button de components/ui
//   · los mismos 6 tipos de evento e i18n de quoteFormScreen.eventTypes.*
//   · client_create_event (sql/690) — creación ATÓMICA, un solo viaje
// Sin librerías nuevas.
//
// ── Lo que NO hace ──────────────────────────────────────────────────────────
// No crea reservaciones, no cotiza, no cobra, no toca wallets ni proveedores.
// Solo crea el contenedor `events` y navega.
// ─────────────────────────────────────────────────────────────────────────────
import { ArrowLeft, CalendarDays, Clock, MapPin } from 'lucide-react-native';
import React, { useMemo, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { Calendar } from 'react-native-calendars';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useTranslation } from 'react-i18next';
import { supabase } from '../../config/supabase';
import { COLORS, FONTS, RADIUS, SPACING } from '../../config/theme';
import Button from '../../components/ui/Button';
import Input from '../../components/ui/Input';
import TimePickerModal from '../../components/ui/TimePickerModal';
import MapAddressPicker, { AddressResult } from '../../components/ui/MapAddressPicker';

// Mismos 6 valores del CHECK de events.event_type / quotes.event_type.
const EVENT_TYPE_KEYS = ['fiesta_privada', 'boda', 'cumpleanos', 'graduacion', 'empresarial', 'otro'] as const;

const onlyDigits = (s: string) => s.replace(/[^0-9]/g, '');
const TOTAL_STEPS = 2;

export default function PartyBuilderScreen({ navigation }: any) {
  const { t, i18n } = useTranslation();
  const dateLocale = i18n.language?.startsWith('en') ? 'en-US' : 'es-MX';

  const [step, setStep] = useState<1 | 2>(1);
  const [saving, setSaving] = useState(false);

  // Paso 1 — qué se festeja
  const [name, setName]           = useState('');
  const [eventType, setEventType] = useState<string | null>(null);
  const [eventDate, setEventDate] = useState('');

  // Paso 2 — dónde y con quién
  const [address, setAddress]     = useState('');
  const [municipio, setMunicipio] = useState('');
  const [estado, setEstado]       = useState('');
  const [startTime, setStartTime] = useState('');
  const [endTime, setEndTime]     = useState('');
  const [guests, setGuests]       = useState('');
  const [budget, setBudget]       = useState('');

  const [calendarOpen, setCalendarOpen] = useState(false);
  const [mapOpen, setMapOpen]           = useState(false);
  const [startOpen, setStartOpen]       = useState(false);
  const [endOpen, setEndOpen]           = useState(false);

  // Único estado inválido que la UI permite teclear (los campos filtran a
  // dígitos): un 0 de invitados. Se marca en el propio campo.
  const guestsError = guests !== '' && parseInt(guests, 10) === 0
    ? t('partyBuilder.errors.invalidGuests')
    : undefined;

  const step1Ready = !!eventDate;                         // la fecha es lo único obligatorio del paso 1
  const step2Ready = !!address.trim() && !!startTime && !guestsError;

  const prettyDate = useMemo(
    () => (eventDate
      ? new Date(eventDate + 'T12:00:00').toLocaleDateString(dateLocale, { day: 'numeric', month: 'long', year: 'numeric' })
      : ''),
    [eventDate, dateLocale],
  );

  const onConfirmAddress = (r: AddressResult) => {
    setAddress(r.address);
    setMunicipio(r.municipio);
    setEstado(r.estado);
    setMapOpen(false);
  };

  const crear = async () => {
    if (!step2Ready) return;
    setSaving(true);
    const { data, error } = await supabase.rpc('client_create_event', {
      p_event_date:  eventDate,
      p_event_time:  startTime,
      p_address:     address.trim(),
      p_name:        name.trim() || null,
      p_event_type:  eventType,
      p_municipio:   municipio.trim() || null,
      p_estado:      estado.trim() || null,
      p_guest_count: guests.trim() ? parseInt(onlyDigits(guests), 10) : null,
      p_budget_max:  budget.trim() ? parseInt(onlyDigits(budget), 10) : null,
      p_end_time:    endTime || null,
    });
    setSaving(false);

    if (error || !data?.ok) {
      const code = data?.error ?? error?.message ?? '';
      const key =
        code.includes('missing_event_date')   ? 'partyBuilder.errors.missingDate'
        : code.includes('missing_address')    ? 'partyBuilder.errors.missingAddress'
        : code.includes('missing_event_time') ? 'partyBuilder.errors.missingTime'
        : code.includes('invalid_event_time') || code.includes('invalid_end_time')
                                              ? 'partyBuilder.errors.invalidTime'
        : code.includes('invalid_event_type') ? 'partyBuilder.errors.invalidType'
        : code.includes('invalid_guest_count')? 'partyBuilder.errors.invalidGuests'
        : code.includes('invalid_budget')     ? 'partyBuilder.errors.invalidBudget'
        : code.includes('not_authenticated')  ? 'partyBuilder.errors.noSession'
        : 'partyBuilder.errors.generic';
      Alert.alert(t('partyBuilder.errors.title'), t(key));
      return;
    }

    // Al hub de servicios YA EXISTENTE, con el contexto del evento. De aquí en
    // adelante el event_id viaja por la cadena que ya funcionaba desde sql/585.
    navigation.replace('EventCategoryPicker', {
      eventId:      data.event_id,
      eventDate:    eventDate,
      eventAddress: address.trim(),
    });
  };

  return (
    <View style={s.root}>
      <SafeAreaView edges={['top']} style={s.header}>
        <Pressable
          style={s.backBtn}
          hitSlop={6}
          onPress={() => (step === 1 ? navigation.goBack() : setStep(1))}
        >
          <ArrowLeft size={20} color={COLORS.text} />
        </Pressable>
        <View style={{ flex: 1 }}>
          <Text style={s.headerTitle}>{t('partyBuilder.headerTitle')}</Text>
          <Text style={s.headerSub}>{t('partyBuilder.stepOf', { step, total: TOTAL_STEPS })}</Text>
        </View>
      </SafeAreaView>

      {/* Barra de progreso — mismo patrón que GuidedRequestScreen */}
      <View style={s.progressWrap}>
        <View style={s.progressTrack}>
          <View style={[s.progressFill, { width: `${(step / TOTAL_STEPS) * 100}%` }]} />
        </View>
      </View>

      <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <ScrollView contentContainerStyle={s.scroll} keyboardShouldPersistTaps="handled">
          {step === 1 ? (
            <>
              <Text style={s.lead}>{t('partyBuilder.step1Lead')}</Text>

              <Input
                label={t('partyBuilder.nameLabel')}
                placeholder={t('partyBuilder.namePlaceholder')}
                value={name}
                onChangeText={setName}
                maxLength={80}
              />

              <Text style={s.fieldLabel}>{t('partyBuilder.typeLabel')}</Text>
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

              <Text style={s.fieldLabel}>{t('partyBuilder.dateLabel')}</Text>
              <Pressable
                style={[s.pickerRow, !!eventDate && s.pickerRowActive]}
                onPress={() => setCalendarOpen(true)}
              >
                <CalendarDays size={16} color={eventDate ? COLORS.green : COLORS.muted2} />
                <Text style={[s.pickerText, !!eventDate && s.pickerTextActive]}>
                  {prettyDate || t('partyBuilder.datePlaceholder')}
                </Text>
              </Pressable>
              <Text style={s.hint}>{t('partyBuilder.dateHint')}</Text>

              <View style={{ height: 8 }} />
              <Button
                label={t('partyBuilder.next')}
                onPress={() => setStep(2)}
                disabled={!step1Ready}
              />
              <Text style={s.footerNote}>{t('partyBuilder.optionalNote')}</Text>
            </>
          ) : (
            <>
              <Text style={s.lead}>{t('partyBuilder.step2Lead')}</Text>

              <Text style={s.fieldLabel}>{t('partyBuilder.addressLabel')}</Text>
              <Pressable
                style={[s.pickerRow, !!address && s.pickerRowActive]}
                onPress={() => setMapOpen(true)}
              >
                <MapPin size={16} color={address ? COLORS.green : COLORS.muted2} />
                <Text style={[s.pickerText, !!address && s.pickerTextActive]} numberOfLines={2}>
                  {address || t('partyBuilder.addressPlaceholder')}
                </Text>
              </Pressable>
              {(!!municipio || !!estado) && (
                <Text style={s.hint}>{[municipio, estado].filter(Boolean).join(', ')}</Text>
              )}

              <Text style={s.fieldLabel}>{t('partyBuilder.startTimeLabel')}</Text>
              <Pressable
                style={[s.pickerRow, !!startTime && s.pickerRowActive]}
                onPress={() => setStartOpen(true)}
              >
                <Clock size={16} color={startTime ? COLORS.green : COLORS.muted2} />
                <Text style={[s.pickerText, !!startTime && s.pickerTextActive]}>
                  {startTime || t('partyBuilder.startTimePlaceholder')}
                </Text>
              </Pressable>

              <Text style={s.fieldLabel}>{t('partyBuilder.endTimeLabel')}</Text>
              <View style={[s.pickerRow, !!endTime && s.pickerRowActive]}>
                <Pressable style={s.pickerMain} onPress={() => setEndOpen(true)}>
                  <Clock size={16} color={endTime ? COLORS.green : COLORS.muted2} />
                  <Text style={[s.pickerText, !!endTime && s.pickerTextActive]}>
                    {endTime || t('partyBuilder.endTimePlaceholder')}
                  </Text>
                </Pressable>
                {!!endTime && (
                  <Pressable onPress={() => setEndTime('')} hitSlop={12} style={s.clearBtn}>
                    <Text style={s.clearText}>{t('partyBuilder.clear')}</Text>
                  </Pressable>
                )}
              </View>
              <Text style={s.hint}>{t('partyBuilder.endTimeHint')}</Text>

              <Input
                label={t('partyBuilder.guestsLabel')}
                placeholder={t('partyBuilder.guestsPlaceholder')}
                value={guests}
                onChangeText={v => setGuests(onlyDigits(v))}
                keyboardType="number-pad"
                maxLength={6}
                error={guestsError}
              />

              <Input
                label={t('partyBuilder.budgetLabel')}
                placeholder={t('partyBuilder.budgetPlaceholder')}
                value={budget}
                onChangeText={v => setBudget(onlyDigits(v))}
                keyboardType="number-pad"
                maxLength={9}
                icon={<Text style={s.currencyAdornment}>$</Text>}
              />
              <Text style={s.hint}>{t('partyBuilder.budgetHint')}</Text>

              <View style={{ height: 8 }} />
              <Button
                label={t('partyBuilder.create')}
                onPress={crear}
                loading={saving}
                disabled={!step2Ready}
              />
              <Text style={s.footerNote}>{t('partyBuilder.createNote')}</Text>
            </>
          )}
          <View style={{ height: 40 }} />
        </ScrollView>
      </KeyboardAvoidingView>

      {saving && (
        <View style={s.savingOverlay}>
          <ActivityIndicator color={COLORS.green} size="large" />
          <Text style={s.savingText}>{t('partyBuilder.creating')}</Text>
        </View>
      )}

      {/* ── Calendario (mismo tema que QuoteFormScreen) ───────────────────── */}
      <Modal visible={calendarOpen} transparent animationType="slide">
        <View style={s.calOverlay}>
          <View style={s.calSheet}>
            <Text style={s.calTitle}>{t('partyBuilder.dateLabel')}</Text>
            <Calendar
              onDayPress={(day: any) => { setEventDate(day.dateString); setCalendarOpen(false); }}
              markedDates={eventDate ? { [eventDate]: { selected: true, selectedColor: COLORS.green } } : {}}
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
              <Text style={s.calCloseText}>{t('partyBuilder.cancel')}</Text>
            </Pressable>
          </View>
        </View>
      </Modal>

      <MapAddressPicker
        visible={mapOpen}
        onConfirm={onConfirmAddress}
        onClose={() => setMapOpen(false)}
      />

      <TimePickerModal
        visible={startOpen}
        value={startTime || '20:00'}
        title={t('partyBuilder.startTimeLabel')}
        onConfirm={(v: string) => { setStartTime(v); setStartOpen(false); }}
        onClose={() => setStartOpen(false)}
      />
      <TimePickerModal
        visible={endOpen}
        value={endTime || '02:00'}
        title={t('partyBuilder.endTimeLabel')}
        onConfirm={(v: string) => { setEndTime(v); setEndOpen(false); }}
        onClose={() => setEndOpen(false)}
      />
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: COLORS.bg },

  // Header estándar de FORMULARIO (theme.ts)
  header: {
    flexDirection: 'row', alignItems: 'center', gap: 14,
    paddingHorizontal: SPACING.xl, paddingVertical: 12,
  },
  backBtn: {
    width: 40, height: 40, borderRadius: 12,
    backgroundColor: COLORS.card, borderWidth: 1, borderColor: COLORS.border,
    alignItems: 'center', justifyContent: 'center',
  },
  headerTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text },
  headerSub:   { fontFamily: FONTS.body, fontSize: 12, color: COLORS.muted2, marginTop: 1 },

  // Progreso — mismo patrón que GuidedRequestScreen
  progressWrap:  { paddingHorizontal: SPACING.xl, paddingBottom: 12 },
  progressTrack: { width: '100%', height: 4, backgroundColor: COLORS.border, borderRadius: 2 },
  progressFill:  { height: 4, backgroundColor: COLORS.green, borderRadius: 2 },

  scroll: { padding: SPACING.xl, paddingTop: 4, paddingBottom: 60 },
  lead: {
    fontFamily: FONTS.bodySemiBold, fontSize: 18, color: COLORS.text,
    lineHeight: 25, marginBottom: 20,
  },

  fieldLabel: { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2, marginBottom: 8 },
  hint:  { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: -4, marginBottom: 16, lineHeight: 16 },
  footerNote: { fontFamily: FONTS.body, fontSize: 11, color: COLORS.muted, marginTop: 10, textAlign: 'center', lineHeight: 16 },
  currencyAdornment: { fontFamily: FONTS.bodySemiBold, fontSize: 14, color: COLORS.muted2 },

  // Chips — mismo vocabulario que QuoteFormScreen, superficie card2 para
  // igualar el componente Input (que es card2 por dentro).
  chipGrid: { flexDirection: 'row', gap: 10, flexWrap: 'wrap', marginBottom: 20 },
  chipWide: {
    paddingHorizontal: 14, paddingVertical: 10, borderRadius: RADIUS.lg,
    backgroundColor: COLORS.card2, borderWidth: 1, borderColor: COLORS.border,
  },
  chipActive:     { backgroundColor: 'rgba(0,230,118,0.12)', borderColor: COLORS.green },
  chipText:       { fontFamily: FONTS.bodyMedium, fontSize: 13, color: COLORS.muted2 },
  chipTextActive: { color: COLORS.green },

  // Filas de selección (fecha, dirección, horas) — mismo comportamiento que el
  // timeChip de QuoteFormScreen: cuando tienen valor se ponen verdes.
  pickerRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    backgroundColor: COLORS.card2, borderRadius: RADIUS.md,
    borderWidth: 1, borderColor: COLORS.border,
    paddingHorizontal: 14, marginBottom: 16, minHeight: 50,
  },
  pickerRowActive: { borderColor: COLORS.green, backgroundColor: 'rgba(0,230,118,0.08)' },
  pickerMain: { flex: 1, flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 15 },
  pickerText: { flex: 1, fontFamily: FONTS.body, fontSize: 15, color: COLORS.muted, paddingVertical: 15 },
  pickerTextActive: { fontFamily: FONTS.bodySemiBold, color: COLORS.green },
  clearBtn:  { paddingVertical: 15, paddingLeft: 12 },
  clearText: { fontFamily: FONTS.bodyMedium, fontSize: 12, color: COLORS.muted2 },

  savingOverlay: {
    position: 'absolute', top: 0, right: 0, bottom: 0, left: 0,
    backgroundColor: COLORS.overlay, alignItems: 'center', justifyContent: 'center', gap: 14,
  },
  savingText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.text },

  // Calendario — mismos estilos que QuoteFormScreen
  calOverlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.7)', justifyContent: 'flex-end' },
  calSheet: {
    backgroundColor: COLORS.card, borderTopLeftRadius: RADIUS.xl, borderTopRightRadius: RADIUS.xl,
    padding: SPACING.lg, paddingBottom: 40,
  },
  calTitle: { fontFamily: FONTS.bodySemiBold, fontSize: 16, color: COLORS.text, marginBottom: 12, textAlign: 'center' },
  calClose: { alignItems: 'center', paddingVertical: 14, marginTop: 8 },
  calCloseText: { fontFamily: FONTS.bodyMedium, fontSize: 14, color: COLORS.muted2 },
});
